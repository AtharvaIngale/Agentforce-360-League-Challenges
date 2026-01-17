public with sharing class DiabetesCareObservationTriggerHandler {
    /**
     * Handle after insert trigger context for CareObservation.
     * Bulkified: delegates to processObservations.
     */
    public static void handleAfterInsert(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return; // Return Early
        }
        processObservations(newObservations);
    }

    /**
     * Handle after update trigger context for CareObservation.
     * Bulkified: delegates to processObservations.
     */
    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return; // Return Early
        }
        processObservations(newObservations);
    }

    /**
     * Core processing for HbA1c observations.
     * - Uses CMT thresholds
     * - No SOQL/DML in loops
     * - Creates Tasks in bulk with required fields
     */
    private static void processObservations(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return; // Return Early
        }

        // Get thresholds from Custom Metadata (cached automatically)
        Diabetes_Threshold__mdt thresholds = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];
        if (thresholds == null) {
            // Defensive: no thresholds configured; return early to avoid null dereference
            return;
        }

        List<Task> tasksToCreate = new List<Task>();
        Set<Id> observationIds = new Set<Id>();
        Set<Id> codeIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        // First pass: collect Code IDs to query
        for (CareObservation obs : newObservations) {
            if (obs != null && obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        // Query CodeSet records to get code names (guard against empty set)
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            codeMap = new Map<Id, CodeSet>(
                [SELECT Id, Name FROM CodeSet WHERE Id IN :codeIds]
            );
        }

        // Second pass: collect observation IDs and HbA1c values for bulk processing
        for (CareObservation obs : newObservations) {
            if (obs == null) continue;

            CodeSet code = codeMap.get(obs.CodeId);
            String codeName = (code != null && code.Name != null) ? code.Name.trim().toLowerCase() : null;

            // Normalize status/value type checks to be robust to case differences
            String status = (obs.ObservationStatus == null) ? null : obs.ObservationStatus.trim().toLowerCase();
            String valueType = (obs.ObservedValueType == null) ? null : obs.ObservedValueType.trim().toLowerCase();

            // Only process finalized HbA1c observations with valid data
            if (codeName == 'hba1c'
                && status == 'final'
                && valueType == 'quantity'
                && obs.ObservedValueNumerator != null
                && thresholds.Warning_Percentage__c != null
                && obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c
                && obs.ObservedSubjectId != null
                && obs.Id != null) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (observationIds.isEmpty()) {
            return; // Return Early: nothing to do
        }

        // Bulk query existing tasks once for all observations (fixes: no SOQL in loop)
        Map<Id, List<Task>> existingTasksByObservation = new Map<Id, List<Task>>();
        List<Task> existingTasks = [
            SELECT Id, WhatId, Subject, Status, CreatedDate
            FROM Task
            WHERE WhatId IN :observationIds
              AND Subject LIKE 'HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ];
        for (Task t : existingTasks) {
            List<Task> bucket = existingTasksByObservation.get(t.WhatId);
            if (bucket == null) {
                bucket = new List<Task>();
                existingTasksByObservation.put(t.WhatId, bucket);
            }
            bucket.add(t);
        }

        Date today = Date.today();

        // Build tasks (no DML in loop; ensure required fields)
        for (Id observationId : observationIds) {
            List<Task> existingForObs = existingTasksByObservation.get(observationId);
            if (existingForObs != null && !existingForObs.isEmpty()) {
                continue; // Skip if open follow-up already exists
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);
            // Null-safe description content
            String hba1cText = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue);

            Task followUpTask = new Task();
            followUpTask.Subject = 'HbA1c Follow-up Required - ' + today.format();
            followUpTask.WhatId = observationId; // Link to CareObservation
            // Set required ActivityDate (due date)
            followUpTask.ActivityDate = today.addDays(7);

            // Use metadata thresholds for priority
            if (hba1cValue != null && thresholds.Critical_Percentage__c != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.Priority = 'High';
            } else if (hba1cValue != null && thresholds.Warning_Percentage__c != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                followUpTask.Priority = 'Normal';
            } else {
                followUpTask.Priority = 'Low';
            }

            // Set a safe default Status and Type if org doesn't have these picklist values
            followUpTask.Status = 'Not Started';
            followUpTask.Type = 'Call';

            followUpTask.Description =
                'Patient has new HbA1c level of ' + hba1cText + '%. '
                + 'Schedule follow-up appointment to review diabetes management plan and medication adherence. '
                + 'Thresholds: Target <' + String.valueOf(thresholds.Target_Percentage__c)
                + '%, Warning ≥' + String.valueOf(thresholds.Warning_Percentage__c)
                + '%, Critical ≥' + String.valueOf(thresholds.Critical_Percentage__c) + '%.';

            tasksToCreate.add(followUpTask);
        }

        if (!tasksToCreate.isEmpty()) {
            // Bulk insert (fixes: no DML in loop); use Database.insert for partial success handling
            try {
                List<Database.SaveResult> saveResults = Database.insert(tasksToCreate, /* allOrNone */ false, AccessLevel.USER_MODE);
                // Optionally, attach errors to context records to surface in the UI
                for (Integer i = 0; i < saveResults.size(); i++) {
                    if (!saveResults[i].isSuccess()) {
                        // No System.debug in prod per rules; in triggers, addError could block the original DML.
                        // We skip addError to avoid import failures; rely on partial success behavior.
                        // If needed, implement a platform event/error log here.
                    }
                }
            } catch (Exception e) {
                // Defensive: if an unexpected exception occurs, abort further processing
                // In a real implementation, consider platform events or error logging framework
                return;
            }
        }
    }
}
