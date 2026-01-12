/**
 * DiabetesCareAssessment
 * Apex class for assessing diabetes care based on HbA1c (glycated hemoglobin) values and program enrollment.
 *
 * Overview:
 * - Invocable from Flow and other automation tools.
 * - Retrieves latest HbA1c CareObservation for each patient.
 * - Determines if patient is enrolled in an active Diabetes care program.
 * - Categorizes risk based on HbA1c value:
 *   - Well Controlled: < 7.0
 *   - Needs Attention: 7.0 - < 9.0
 *   - High Risk/Urgent: ≥ 9.0
 *   - No Data Available: when no valid observation found
 *
 * Security:
 * - with sharing to respect sharing rules.
 * - SOQL queries use WITH SECURITY_ENFORCED where appropriate for user mode reads.
 *
 * Code Quality:
 * - Bulkified processing.
 * - Graceful handling of nulls and empty collections.
 * - Meaningful error messages in result wrapper.
 *
 * Example Usage:
 * - Use the invocable method from a Flow: pass a collection of AssessmentRequest with patientId.
 */
public with sharing class DiabetesCareAssessment {

    /**
     * AssessmentRequest
     * Input wrapper for the invocable method.
     */
    public class AssessmentRequest {
        /**
         * The Salesforce ID of the patient/account to assess.
         */
        @InvocableVariable(label='Patient Id' description='The Salesforce Id of the patient/account to assess' required=true)
        public Id patientId;

        /**
         * Number of days to look back for observations (currently not used).
         */
        @InvocableVariable(label='Days Lookback' description='Number of days to look back for observations (currently not used in implementation)')
        public Integer daysLookback;

        // No-arg constructor
        public AssessmentRequest() {}

        // Parameterized constructor
        public AssessmentRequest(Id patientId, Integer daysLookback) {
            this.patientId = patientId;
            this.daysLookback = daysLookback;
        }
    }

    /**
     * AssessmentResult
     * Output wrapper for the invocable method.
     */
    public class AssessmentResult {
        /**
         * The Salesforce ID of the patient that was assessed.
         */
        @InvocableVariable(label='Patient Id' description='The Salesforce Id of the patient that was assessed')
        public Id patientId;

        /**
         * The latest HbA1c value found for the patient (can be null).
         */
        @InvocableVariable(label='HbA1c Value' description='The latest HbA1c value found for the patient (can be null)')
        public Decimal hba1cValue;

        /**
         * Categorized risk level based on HbA1c value.
         */
        @InvocableVariable(label='Risk Category' description='Categorized risk level based on HbA1c value')
        public String riskCategory;

        /**
         * Indicates whether the patient is enrolled in an active Diabetes care program.
         */
        @InvocableVariable(label='In Diabetes Program' description='Indicates whether the patient is enrolled in an active Diabetes care program')
        public Boolean isInDiabetesProgram;

        /**
         * Contains error message if processing failed for this patient (null if successful).
         */
        @InvocableVariable(label='Error Message' description='Contains error message if processing failed for this patient (null if successful)')
        public String errorMessage;

        // No-arg constructor
        public AssessmentResult() {}

        // Parameterized constructor
        public AssessmentResult(Id patientId) {
            this.patientId = patientId;
        }
    }

    /**
     * Invocable entry point
     * Assesses patient diabetes care based on HbA1c values and program enrollment.
     *
     * @param requests List of AssessmentRequest wrapper instances
     * @return List of AssessmentResult wrapper instances, one per input
     */
    @InvocableMethod(label='Assess Patient' description='Assesses patient diabetes care based on HbA1c values and program enrollment')
    public static List<AssessmentResult> assessPatient(List<AssessmentRequest> requests) {
        // 1) Input validation
        if (requests == null || requests.isEmpty()) {
            return new List<AssessmentResult>();
        }

        // 2) Patient ID extraction and mapping
        Set<Id> patientIds = new Set<Id>();
        Map<Id, AssessmentRequest> idToRequest = new Map<Id, AssessmentRequest>();
        for (AssessmentRequest req : requests) {
            if (req != null && req.patientId != null) {
                patientIds.add(req.patientId);
                idToRequest.put(req.patientId, req);
            }
        }

        List<AssessmentResult> results = new List<AssessmentResult>();

        // If no valid patient Ids, return empty results (or results aligned to requests with errors)
        if (patientIds.isEmpty()) {
            // Return empty set of results, because there are no valid patient Ids to process
            return results;
        }

        // 3) HbA1c CodeSet lookup
        Id hba1cCodeSetId = getHbA1cCodeSetId();
        if (hba1cCodeSetId == null) {
            for (Id pid : patientIds) {
                AssessmentResult res = new AssessmentResult(pid);
                res.errorMessage = 'HbA1c CodeSet not found in the system';
                res.riskCategory = 'No Data Available';
                res.isInDiabetesProgram = false;
                results.add(res);
            }
            return results;
        }

        // 4) Data retrieval
        Map<Id, CareObservation> latestObsByPatient = getLatestHbA1cObservations(patientIds, hba1cCodeSetId);
        Map<Id, Boolean> diabetesEnrollment = checkActiveDiabetesPrograms(patientIds);

        // 5) Result processing
        for (Id pid : patientIds) {
            AssessmentResult res = new AssessmentResult(pid);
            try {
                CareObservation obs = latestObsByPatient.get(pid);

                if (obs != null && obs.ObservedValueNumerator != null) {
                    res.hba1cValue = obs.ObservedValueNumerator;
                    // Risk categorization
                    if (res.hba1cValue < 7.0) {
                        res.riskCategory = 'Well Controlled';
                    } else if (res.hba1cValue >= 7.0 && res.hba1cValue < 9.0) {
                        res.riskCategory = 'Needs Attention';
                    } else if (res.hba1cValue >= 9.0) {
                        res.riskCategory = 'High Risk/Urgent';
                    }
                } else {
                    res.riskCategory = 'No Data Available';
                }

                // Program enrollment
                res.isInDiabetesProgram = diabetesEnrollment.containsKey(pid) ? diabetesEnrollment.get(pid) : false;

            } catch (Exception e) {
                res.errorMessage = 'Error processing patient ' + String.valueOf(pid) + ': ' + e.getMessage();
            }
            results.add(res);
        }

        // 6) Return results
        return results;
    }

    /**
     * Retrieves the Salesforce ID of the CodeSet record named 'HbA1c'.
     *
     * @return Id of the HbA1c CodeSet, or null if not found
     */
    private static Id getHbA1cCodeSetId() {
        // Query CodeSet using security enforcement where appropriate
        List<CodeSet> cs = [
            SELECT Id
            FROM CodeSet
            WHERE Name = 'HbA1c'
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        return cs.isEmpty() ? null : cs[0].Id;
    }

    /**
     * Retrieves the most recent finalized HbA1c observation (quantity with numerator) for each patient.
     *
     * @param patientIds Set of patient/account Ids
     * @param hba1cCodeSetId Id of the HbA1c CodeSet
     * @return Map of Patient Id to latest CareObservation
     */
    private static Map<Id, CareObservation> getLatestHbA1cObservations(Set<Id> patientIds, Id hba1cCodeSetId) {
        Map<Id, CareObservation> result = new Map<Id, CareObservation>();
        if (patientIds == null || patientIds.isEmpty() || hba1cCodeSetId == null) {
            return result;
        }

        // Query latest observations ordered by EffectiveDateTime desc
        List<CareObservation> obsList = [
            SELECT Id, ObservedSubjectId, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE CodeId = :hba1cCodeSetId
              AND ObservedSubjectId IN :patientIds
              AND ObservationStatus = 'Final'
              AND ObservedValueType = 'Quantity'
              AND ObservedValueNumerator != null
            WITH SECURITY_ENFORCED
            ORDER BY EffectiveDateTime DESC NULLS LAST
            LIMIT 1000
        ];

        // Take first encountered per patient (ordered desc ensures latest first)
        for (CareObservation obs : obsList) {
            Id subj = obs.ObservedSubjectId;
            if (subj == null) continue;
            if (!result.containsKey(subj)) {
                result.put(subj, obs);
            }
        }
        return result;
    }

    /**
     * Determines which patients are enrolled in active Diabetes care programs.
     *
     * @param patientIds Set of patient/account Ids
     * @return Map of Patient Id to Boolean (true if enrolled in an active Diabetes program)
     */
    private static Map<Id, Boolean> checkActiveDiabetesPrograms(Set<Id> patientIds) {
        Map<Id, Boolean> enrollment = new Map<Id, Boolean>();
        if (patientIds == null || patientIds.isEmpty()) {
            return enrollment;
        }

        // Initialize map with default false
        for (Id pid : patientIds) {
            enrollment.put(pid, false);
        }

        // Query for active enrollments in programs with Name like %Diabetes%
        List<CareProgramEnrollee> enrollees = [
            SELECT Id, CareProgramId, AccountId, Status
            FROM CareProgramEnrollee
            WHERE AccountId IN :patientIds
              AND Status = 'Active'
              AND CareProgramId IN (
                  SELECT Id FROM CareProgram WHERE Name LIKE '%Diabetes%'
              )
            WITH SECURITY_ENFORCED
        ];

        for (CareProgramEnrollee cpe : enrollees) {
            if (cpe.AccountId != null) {
                enrollment.put(cpe.AccountId, true);
            }
        }

        return enrollment;
    }
}
