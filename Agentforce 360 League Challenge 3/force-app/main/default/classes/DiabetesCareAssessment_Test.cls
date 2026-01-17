@IsTest
private class DiabetesCareAssessment_Test {

    @TestSetup
    static void setupData() {
        // Patients (Accounts)
        List<Account> patients = new List<Account>{
            new Account(Name = 'Patient A'),  // Will get HbA1c 6.5 (Well Controlled), enrolled
            new Account(Name = 'Patient B'),  // Will get HbA1c 7.5 (Needs Attention), not enrolled
            new Account(Name = 'Patient C'),  // Will get HbA1c 9.5 (High Risk/Urgent), enrolled
            new Account(Name = 'Patient D')   // No observation
        };
        insert patients;

        // CodeSet HbA1c
        CodeSet hba1cCode = new CodeSet(Name = 'HbA1c');
        insert hba1cCode;

        // CareProgram - Diabetes
        CareProgram diabetesProgram = new CareProgram(Name = 'Comprehensive Diabetes Care');
        insert diabetesProgram;

        // CareProgramEnrollee - enroll A and C as Active
        List<CareProgramEnrollee> enrollees = new List<CareProgramEnrollee>{
            new CareProgramEnrollee(AccountId = patients[0].Id, CareProgramId = diabetesProgram.Id, Status = 'Active'),
            new CareProgramEnrollee(AccountId = patients[2].Id, CareProgramId = diabetesProgram.Id, Status = 'Active')
        };
        insert enrollees;

        // Observations:
        // Patient A: Final, Quantity, 6.5 (Well Controlled)
        // Patient B: Final, Quantity, 7.5 (Needs Attention)
        // Patient C: Final, Quantity, 9.5 (High Risk)
        // Also add an older observation for B to ensure latest picked by EffectiveDateTime
        DateTime nowTs = System.now();
        List<CareObservation> observations = new List<CareObservation>{
            new CareObservation(
                ObservedSubjectId = patients[0].Id,
                CodeId = hba1cCode.Id,
                ObservationStatus = 'Final',
                ObservedValueType = 'Quantity',
                ObservedValueNumerator = 6.5,
                EffectiveDateTime = nowTs.addDays(-1)
            ),
            new CareObservation(
                ObservedSubjectId = patients[1].Id,
                CodeId = hba1cCode.Id,
                ObservationStatus = 'Final',
                ObservedValueType = 'Quantity',
                ObservedValueNumerator = 7.0,
                EffectiveDateTime = nowTs.addDays(-10)
            ),
            new CareObservation(
                ObservedSubjectId = patients[1].Id,
                CodeId = hba1cCode.Id,
                ObservationStatus = 'Final',
                ObservedValueType = 'Quantity',
                ObservedValueNumerator = 7.5,
                EffectiveDateTime = nowTs // latest
            ),
            new CareObservation(
                ObservedSubjectId = patients[2].Id,
                CodeId = hba1cCode.Id,
                ObservationStatus = 'Final',
                ObservedValueType = 'Quantity',
                ObservedValueNumerator = 9.5,
                EffectiveDateTime = nowTs.addHours(-2)
            )
        };
        insert observations;

        // Non-HbA1c code to ensure filter works
        CodeSet otherCode = new CodeSet(Name = 'LDL');
        insert otherCode;
        insert new CareObservation(
            ObservedSubjectId = patients[0].Id,
            CodeId = otherCode.Id,
            ObservationStatus = 'Final',
            ObservedValueType = 'Quantity',
            ObservedValueNumerator = 100,
            EffectiveDateTime = nowTs
        );
    }

    @IsTest
    static void assessPatients_fullPathAndEdgeCases() {
        // Gather patients
        List<Account> pats = [SELECT Id, Name FROM Account WHERE Name LIKE 'Patient %' ORDER BY Name];

        // Build requests including a null and a request with null patientId to test robustness
        List<DiabetesCareAssessment.AssessmentRequest> reqs = new List<DiabetesCareAssessment.AssessmentRequest>();
        // Valid requests for A, B, C, D
        for (Account a : pats) {
            reqs.add(new DiabetesCareAssessment.AssessmentRequest(a.Id, 365));
        }
        // Add a null wrapper and a wrapper with null Id
        reqs.add(null);
        reqs.add(new DiabetesCareAssessment.AssessmentRequest(null, 30));

        Test.startTest();
        List<DiabetesCareAssessment.AssessmentResult> results =
            DiabetesCareAssessment.assessPatient(reqs);
        Test.stopTest();

        System.assertEquals(reqs.size(), results.size(), 'Output should match input size including nulls');

        // Map by patient
        Map<Id, DiabetesCareAssessment.AssessmentResult> byPid = new Map<Id, DiabetesCareAssessment.AssessmentResult>();
        for (DiabetesCareAssessment.AssessmentResult r : results) {
            if (r != null && r.patientId != null && !byPid.containsKey(r.patientId)) {
                byPid.put(r.patientId, r);
            }
        }

        // Fetch patients by name for explicit assertions
        Account pA = [SELECT Id FROM Account WHERE Name = 'Patient A' LIMIT 1];
        Account pB = [SELECT Id FROM Account WHERE Name = 'Patient B' LIMIT 1];
        Account pC = [SELECT Id FROM Account WHERE Name = 'Patient C' LIMIT 1];
        Account pD = [SELECT Id FROM Account WHERE Name = 'Patient D' LIMIT 1];

        // A: 6.5 -> Well Controlled, enrolled
        System.assert(byPid.containsKey(pA.Id), 'Result should include Patient A');
        System.assertEquals(6.5, byPid.get(pA.Id).hba1cValue, 'A HbA1c');
        System.assertEquals('Well Controlled', byPid.get(pA.Id).riskCategory, 'A category');
        System.assertEquals(true, byPid.get(pA.Id).isInDiabetesProgram, 'A enrolled');

        // B: latest 7.5 -> Needs Attention, not enrolled
        System.assert(byPid.containsKey(pB.Id), 'Result should include Patient B');
        System.assertEquals(7.5, byPid.get(pB.Id).hba1cValue, 'B HbA1c');
        System.assertEquals('Needs Attention', byPid.get(pB.Id).riskCategory, 'B category');
        System.assertEquals(false, byPid.get(pB.Id).isInDiabetesProgram, 'B not enrolled');

        // C: 9.5 -> High Risk/Urgent, enrolled
        System.assert(byPid.containsKey(pC.Id), 'Result should include Patient C');
        System.assertEquals(9.5, byPid.get(pC.Id).hba1cValue, 'C HbA1c');
        System.assertEquals('High Risk/Urgent', byPid.get(pC.Id).riskCategory, 'C category');
        System.assertEquals(true, byPid.get(pC.Id).isInDiabetesProgram, 'C enrolled');

        // D: No observation -> No Data Available, not enrolled
        System.assert(byPid.containsKey(pD.Id), 'Result should include Patient D');
        System.assertEquals(null, byPid.get(pD.Id).hba1cValue, 'D HbA1c should be null');
        System.assertEquals('No Data Available', byPid.get(pD.Id).riskCategory, 'D category');
        System.assertEquals(false, byPid.get(pD.Id).isInDiabetesProgram, 'D not enrolled');

        // Validate that an entry corresponding to null wrapper yields error message and defaults
        Integer nullWrapperCount = 0;
        Integer nullIdCount = 0;
        for (DiabetesCareAssessment.AssessmentResult r : results) {
            if (r != null && r.patientId == null && r.errorMessage != null && r.errorMessage.contains('Patient Id not provided')) {
                nullIdCount++;
            }
            if (r == null) {
                nullWrapperCount++;
            }
        }
        System.assertEquals(0, nullWrapperCount, 'Results should not contain null entries');
        System.assertEquals(1, nullIdCount, 'There should be one result with null patient Id error');
    }

    @IsTest
    static void assessPatients_missingCodeSet() {
        // Delete HbA1c CodeSet to force error path
        List<CodeSet> codes = [SELECT Id FROM CodeSet WHERE Name = 'HbA1c' LIMIT 1];
        if (!codes.isEmpty()) {
            delete codes;
        }

        List<Account> pats = [SELECT Id FROM Account WHERE Name IN ('Patient A','Patient B') ORDER BY Name];
        List<DiabetesCareAssessment.AssessmentRequest> reqs = new List<DiabetesCareAssessment.AssessmentRequest>();
        for (Account a : pats) {
            reqs.add(new DiabetesCareAssessment.AssessmentRequest(a.Id, 30));
        }

        Test.startTest();
        List<DiabetesCareAssessment.AssessmentResult> results =
            DiabetesCareAssessment.assessPatient(reqs);
        Test.stopTest();

        System.assertEquals(reqs.size(), results.size(), 'Size should match');
        for (DiabetesCareAssessment.AssessmentResult r : results) {
            System.assertEquals('No Data Available', r.riskCategory, 'Risk should be defaulted when missing CodeSet');
            System.assertEquals(false, r.isInDiabetesProgram, 'Enrollment should default to false');
            System.assert(r.errorMessage != null && r.errorMessage.contains('HbA1c CodeSet not found'), 'Should include informative error');
        }
    }

    @IsTest
    static void assessPatients_emptyInput() {
        Test.startTest();
        List<DiabetesCareAssessment.AssessmentResult> results =
            DiabetesCareAssessment.assessPatient(new List<DiabetesCareAssessment.AssessmentRequest>());
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty input should yield empty result');
    }
}
