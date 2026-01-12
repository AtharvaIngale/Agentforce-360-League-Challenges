/**
 * @description Trigger handler for CareObservation to create HbA1c follow-up Tasks based on thresholds.
 * - Bulkified SOQL and DML
 * - Uses Custom Metadata thresholds
 * - Runs DML in USER_MODE
 * - Avoids SOQL/DML in loops and handles nulls safely
 */
public with sharing class DiabetesCareObservationTriggerHandler {

    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    private static void processObservations(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return;
        }

        // Get thresholds from Custom Metadata (cached automatically)
        Diabetes_Threshold__mdt thresholds = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];

        // Collect CodeIds to resolve names once
        Set<Id> codeIds = new Set<Id>();
        for (CareObservation obs : newObservations) {
            if (obs != null && obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        // Resolve CodeSet names
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            codeMap = new Map<Id, CodeSet>([
                SELECT Id, Name
                FROM CodeSet
                WHERE Id IN :codeIds
            ]);
        }

        // Gather candidate observations and values
        Set<Id> observationIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        for (CareObservation obs : newObservations) {
            if (obs == null) continue;

            CodeSet code = obs.CodeId != null ? codeMap.get(obs.CodeId) : null;
            String codeName = (code != null) ? code.Name : null;

            // Only process finalized HbA1c observations with valid data
            if (codeName == 'HbA1c'
                && obs.ObservationStatus == 'final'
                && obs.ObservedValueType == 'Quantity'
                && obs.ObservedValueNumerator != null
                && obs.ObservedSubjectId != null
                && thresholds != null
                && thresholds.Warning_Percentage__c != null
                && obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (observationIds.isEmpty()) {
            return;
        }

        // Query existing open follow-up tasks for these observations in bulk
        Map<Id, Task> existingOpenByWhat = new Map<Id, Task>();
        for (Task t : [
            SELECT Id, WhatId
            FROM Task
            WHERE WhatId IN :observationIds
              AND Subject LIKE '%HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ]) {
            if (t.WhatId != null && !existingOpenByWhat.containsKey(t.WhatId)) {
                existingOpenByWhat.put(t.WhatId, t);
            }
        }

        // Prepare tasks to insert
        List<Task> tasksToCreate = new List<Task>();
        Date today = Date.today();

        for (Id observationId : observationIds) {
            if (existingOpenByWhat.containsKey(observationId)) {
                continue; // skip if an open task exists recently
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);

            Task followUpTask = new Task();
            followUpTask.Subject = 'HbA1c Follow-up Required - ' + today.format();
            followUpTask.WhatId = observationId;

            // Required field: set a near-term due date; escalate sooner for critical
            Date dueDate = today.addDays(7);
            if (thresholds != null && thresholds.Critical_Percentage__c != null
                && hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                dueDate = today.addDays(3);
            }
            followUpTask.ActivityDate = dueDate;

            // Priority based on thresholds
            if (thresholds != null && thresholds.Critical_Percentage__c != null
                && hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.Priority = 'High';
            } else if (thresholds != null && thresholds.Warning_Percentage__c != null
                && hba1cValue != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                followUpTask.Priority = 'Normal';
            } else {
                followUpTask.Priority = 'Low';
            }

            followUpTask.Status = 'Not Started';
            followUpTask.Type = 'Call';

            // Safe description with null guards
            String valueText = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue);
            String targetText = (thresholds != null && thresholds.Target_Percentage__c != null)
                ? String.valueOf(thresholds.Target_Percentage__c) : 'N/A';
            String warnText = (thresholds != null && thresholds.Warning_Percentage__c != null)
                ? String.valueOf(thresholds.Warning_Percentage__c) : 'N/A';
            String critText = (thresholds != null && thresholds.Critical_Percentage__c != null)
                ? String.valueOf(thresholds.Critical_Percentage__c) : 'N/A';

            followUpTask.Description =
                'Patient has new HbA1c level of ' + valueText +
                '%. Schedule follow-up appointment to review diabetes management plan and medication adherence. ' +
                'Thresholds: Target <' + targetText +
                '%, Warning ≥' + warnText +
                '%, Critical ≥' + critText + '%.';

            tasksToCreate.add(followUpTask);
        }

        if (!tasksToCreate.isEmpty()) {
            // Bulk DML in USER_MODE per security requirements
            Database.SaveResult[] results = Database.insert(tasksToCreate, /* allOrNone */ false, AccessLevel.USER_MODE);
            // Optionally, handle errors per-row if needed (omitted for brevity)
        }
    }
}
