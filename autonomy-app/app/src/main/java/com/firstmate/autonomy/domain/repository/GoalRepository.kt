package com.firstmate.autonomy.domain.repository

import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.SurfaceKind
import kotlinx.coroutines.flow.Flow
import java.time.LocalDate

/**
 * Everything the app does to goals, their particulars, and their history.
 *
 * One interface rather than three, because the three levels are never
 * meaningfully edited apart: adding a particular is part of editing a goal, and
 * ticking a day is part of looking at a particular.
 */
interface GoalRepository {

    fun observeGoals(): Flow<List<Goal>>

    fun observeGoal(goalId: Long): Flow<Goal?>

    suspend fun createGoal(title: String, category: String, notes: String): Long

    suspend fun updateGoal(
        goalId: Long,
        title: String,
        category: String,
        notes: String,
        status: GoalStatus,
    )

    suspend fun deleteGoal(goalId: Long)

    suspend fun addParticular(
        goalId: Long,
        title: String,
        kind: SurfaceKind,
        notes: String,
    ): Long

    suspend fun updateParticular(
        particularId: Long,
        goalId: Long,
        title: String,
        kind: SurfaceKind,
        notes: String,
        position: Int,
    )

    suspend fun deleteParticular(particularId: Long)

    /** Ticks or un-ticks one day. Idempotent in both directions. */
    suspend fun setCheckIn(particularId: Long, date: LocalDate, done: Boolean)

    suspend fun addMoment(particularId: Long, label: String, date: LocalDate, note: String): Long

    suspend fun deleteMoment(momentId: Long)
}
