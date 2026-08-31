package com.firstmate.autonomy.domain.repository

import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import kotlinx.coroutines.flow.Flow
import java.time.LocalDate

/** Contract for the decision journal. */
interface DecisionRepository {

    /** All entries, most recent decision date first. */
    fun observeDecisions(): Flow<List<Decision>>

    /** The [limit] most recent entries, for the dashboard. */
    fun observeRecentDecisions(limit: Int): Flow<List<Decision>>

    fun observeDecision(id: Long): Flow<Decision?>

    suspend fun createDecision(
        title: String,
        date: LocalDate,
        category: DecisionCategory,
        myPreference: String,
        finalChoice: String,
        reflection: String,
    ): Long

    suspend fun updateDecision(decision: Decision)

    suspend fun deleteDecision(id: Long)
}
