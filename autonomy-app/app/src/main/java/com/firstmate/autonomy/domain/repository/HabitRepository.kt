package com.firstmate.autonomy.domain.repository

import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitCheckIn
import kotlinx.coroutines.flow.Flow
import java.time.LocalDate

/** Contract for boundary/habit tracking. */
interface HabitRepository {

    /** Active habits in display order. */
    fun observeHabits(): Flow<List<Habit>>

    /** Every check-in inside the inclusive date window. */
    fun observeCheckIns(from: LocalDate, to: LocalDate): Flow<List<HabitCheckIn>>

    suspend fun createHabit(name: String, description: String): Long

    suspend fun updateHabit(habit: Habit)

    /** Archives rather than deletes, so past consistency data survives. */
    suspend fun archiveHabit(id: Long)

    suspend fun deleteHabit(id: Long)

    /** Idempotent: writing the same value twice is a no-op for the user. */
    suspend fun setCheckIn(habitId: Long, date: LocalDate, isCompleted: Boolean)
}
