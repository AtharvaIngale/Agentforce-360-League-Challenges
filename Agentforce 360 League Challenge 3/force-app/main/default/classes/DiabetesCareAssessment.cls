/**
 * Apex class for assessing diabetes care based on HbA1c values and program enrollment.
 *
 * This class exposes an invocable method that can be called from Flow, Process Builder,
 * or other automation tools to assess patients' diabetes care status using:
 *  - Latest HbA1c (glycated hemoglobin) observation value
 *  - Active enrollment in a Diabetes care program
 *
 * Design:
 *  - public with sharing to respect org sharing rules
 *  - Bulkified processing over collections
 *  - Graceful handling of nulls, empty inputs, and missing configuration/data
 *  - Clear wrapper classes for invocable inputs and outputs with labels/descriptions
 *
 * Objects used:
 *  - CodeSet (Name='HbA1c')
 *  - CareObservation (latest finalized HbA1c Quantity with value)
 *  - CareProgram (Name LIKE %Diabetes%)
 *  - CareProgramEnrollee (Status='Active')
 */
public with sharing class DiabetesCareAssessment {

    /**
     * Input wrapper for invocable method.
     */
    public class AssessmentRequest {
        /**
         * The Salesforce ID of the patient/account to assess.
         */
        @InvocableVariable(required=true label='Patient Id' description='The Salesforce Id of the patient/account to assess')
        public Id patientId;

        /**
         * Number of days to look back for observations (currently not used by the assessment logic).
         */
        @InvocableVariable(label='Days Lookback' description='Number of days to look back for observations (currently not used)')
        public Integer daysLookback;

        // No-arg constructor
        public AssessmentRequest() {}

        // Convenience constructor
        public AssessmentRequest(Id patientId, Integer daysLookback) {
            this.patientId = patientId;
            this.daysLookback = daysLookback;
        }
    }

    /**
     * Output wrapper for invocable method.
     */
    public class AssessmentResult {
        /**
         * The Salesforce ID of the patient that was assessed.
         */
        @InvocableVariable(label='Patient Id' description='The Salesforce Id of the patient that was assessed')
        public Id patientId;

        /**
         * The latest HbA1c value found for the patient (can be null if no observation found).
         */
        @InvocableVariable(label='HbA1c Value' description='The latest HbA1c value for the patient, or null if not found')
        public Decimal hba1cValue;

        /**
         * Categorized risk level based on HbA1c value.
         * Values: Well Controlled, Needs Attention, High Risk/Urgent, or No Data Available
         */
        @InvocableVariable(label='Risk Category' description='Risk category based on HbA1c value: Well Controlled, Needs Attention, High Risk/Urgent, or No Data Available')
        public String riskCategory;

        /**
         * Indicates whether the patient is enrolled in an active Diabetes care program.
         */
        @InvocableVariable(label='Enrolled In Diabetes Program' description='True if the patient is enrolled in an active Diabetes care program')
        public Boolean isInDiabetesProgram;

        /**
         * Contains error message if processing failed for this patient (null if successful).
         */
        @InvocableVariable(label='Error Message' description='Error message if processing failed for this patient; null if successful')
        public String errorMessage;

        // No-arg constructor
        public AssessmentResult() {}

        // Convenience constructor
        public AssessmentResult(Id patientId) {
            this.patientId = patientId;
        }
    }

    /**
     * Invocable entry point: assesses diabetes care based on latest HbA1c and program enrollment.
     *
     * Behavior:
     *  - Validates input
     *  - Resolves HbA1c CodeSet Id
     *  - Loads latest HbA1c observations and active Diabetes program enrollments
     *  - Produces one AssessmentResult per input request
     */
    @InvocableMethod(label='Assess Patient' description='Assesses patient diabetes care based on HbA1c values and program enrollment')
    public static List<AssessmentResult> assessPatient(List<AssessmentRequest> requests) {
        List<AssessmentResult> results = new List<AssessmentResult>();

        if (requests == null || requests.isEmpty()) {
            return results; // Return Early
        }

        // Extract patient Ids and map to requests (skip nulls to be robust)
        Set<Id> patientIds = new Set<Id>();
        Map<Id, AssessmentRequest> requestByPatientId = new Map<Id, AssessmentRequest>();
        for (AssessmentRequest req : requests) {
            if (req != null && req.patientId != null) {
                patientIds.add(req.patientId);
                requestByPatientId.put(req.patientId, req);
            }
        }

        // Prepare default results for every input (including null patient Ids) to ensure 1:1 output size
        for (AssessmentRequest req : requests) {
            AssessmentResult res = new AssessmentResult(req == null ? null : req.patientId);
            results.add(res);
        }

        if (patientIds.isEmpty()) {
            // No valid patient Ids; return default results (with patientId possibly null)
            return results;
        }

        // Resolve HbA1c CodeSet Id
        Id hba1cCodeSetId = getHbA1cCodeSetId();
        if (hba1cCodeSetId == null) {
            // Populate error for all results corresponding to provided patient Ids
            for (AssessmentResult res : results) {
                if (res.patientId != null) {
                    res.errorMessage = 'HbA1c CodeSet not found in the system';
                    res.riskCategory = 'No Data Available';
                    res.isInDiabetesProgram = false;
                }
            }
            return results;
        }

        // Retrieve latest observations and active diabetes program enrollment flags
        Map<Id, CareObservation> latestObsByPatient = getLatestHbA1cObservations(patientIds, hba1cCodeSetId);
        Map<Id, Boolean> enrolledByPatient = checkActiveDiabetesPrograms(patientIds);

        // Process each result by patient
        for (AssessmentResult res : results) {
            if (res.patientId == null) {
                res.errorMessage = 'Patient Id not provided';
                res.riskCategory = 'No Data Available';
                res.isInDiabetesProgram = false;
                continue;
            }
            try {
                CareObservation obs = latestObsByPatient.get(res.patientId);
                if (obs != null && obs.ObservedValueNumerator != null) {
                    res.hba1cValue = obs.ObservedValueNumerator;
                    Decimal v = res.hba1cValue;

                    if (v < 7.0) {
                        res.riskCategory = 'Well Controlled';
                    } else if (v >= 7.0 && v < 9.0) {
                        res.riskCategory = 'Needs Attention';
                    } else {
                        res.riskCategory = 'High Risk/Urgent';
                    }
                } else {
                    res.riskCategory = 'No Data Available';
                }

                res.isInDiabetesProgram = enrolledByPatient.containsKey(res.patientId) ? (enrolledByPatient.get(res.patientId) == true) : false;
                // errorMessage stays null on success
            } catch (Exception e) {
                res.errorMessage = 'Error processing patient ' + String.valueOf(res.patientId) + ': ' + e.getMessage();
                if (res.riskCategory == null) {
                    res.riskCategory = 'No Data Available';
                }
                if (res.isInDiabetesProgram == null) {
                    res.isInDiabetesProgram = false;
                }
            }
        }

        return results;
    }

    /**
     * Retrieves the CodeSet Id for Name = 'HbA1c'.
     * @return Id or null if not found
     */
    private static Id getHbA1cCodeSetId() {
        List<CodeSet> codes = [
            SELECT Id
            FROM CodeSet
            WHERE Name = 'HbA1c'
            LIMIT 1
        ];
        return codes.isEmpty() ? null : codes[0].Id;
    }

    /**
     * Retrieves the most recent finalized HbA1c quantity observation with a numeric value for each patient.
     *
     * @param patientIds Set of patient/account Ids
     * @param hba1cCodeSetId The Id of the HbA1c CodeSet
     * @return Map from patient Id to latest CareObservation
     */
    private static Map<Id, CareObservation> getLatestHbA1cObservations(Set<Id> patientIds, Id hba1cCodeSetId) {
        Map<Id, CareObservation> latestByPatient = new Map<Id, CareObservation>();

        if (patientIds == null || patientIds.isEmpty() || hba1cCodeSetId == null) {
            return latestByPatient; // Return Early
        }

        List<CareObservation> obs = [
            SELECT Id, ObservedSubjectId, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE CodeId = :hba1cCodeSetId
              AND ObservedSubjectId IN :patientIds
              AND ObservationStatus = 'Final'
              AND ObservedValueType = 'Quantity'
              AND ObservedValueNumerator != null
            ORDER BY EffectiveDateTime DESC NULLS LAST
            LIMIT 1000
        ];

        for (CareObservation co : obs) {
            if (co.ObservedSubjectId == null) continue;
            // First seen due to DESC order is the latest
            if (!latestByPatient.containsKey(co.ObservedSubjectId)) {
                latestByPatient.put(co.ObservedSubjectId, co);
            }
        }
        return latestByPatient;
    }

    /**
     * Determines which patients are enrolled in active Diabetes programs.
     *
     * @param patientIds Set of patient/account Ids
     * @return Map from patient Id to boolean enrollment flag (default false)
     */
    private static Map<Id, Boolean> checkActiveDiabetesPrograms(Set<Id> patientIds) {
        Map<Id, Boolean> enrolled = new Map<Id, Boolean>();
        if (patientIds == null || patientIds.isEmpty()) {
            return enrolled; // Return Early
        }

        // Initialize defaults
        for (Id pid : patientIds) {
            enrolled.put(pid, false);
        }

        // Query active enrollees in Diabetes programs
        List<CareProgramEnrollee> enrollees = [
            SELECT Id, CareProgramId, AccountId, Status
            FROM CareProgramEnrollee
            WHERE AccountId IN :patientIds
              AND Status = 'Active'
              AND CareProgramId IN (
                    SELECT Id FROM CareProgram WHERE Name LIKE '%Diabetes%'
              )
            LIMIT 5000
        ];

        for (CareProgramEnrollee e : enrollees) {
            if (e.AccountId != null) {
                enrolled.put(e.AccountId, true);
            }
        }
        return enrolled;
    }
}
