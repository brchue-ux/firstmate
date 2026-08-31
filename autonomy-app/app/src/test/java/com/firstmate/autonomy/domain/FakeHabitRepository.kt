package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitCheckIn
import com.firstmate.autonomy.domain.repository.HabitRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import java.time.LocalDate

/**
 * In-memory stand-in for the Room-backed repository.
 *
 * Mirrors the real one's sparse storage: only completed days are held, so a
 * missing entry means "not done" here too.
 */
class FakeHabitRepository(
    initialHabits: List<Habit> = emptyList(),
    initialCompletedDays: Set<Pair<Long, LocalDate>> = emptySet(),
) : HabitRepository {

    private val habits = MutableStateFlow(initialHabits)
    private val completed = MutableStateFlow(initialCompletedDays)

    override fun observeHabits(): Flow<List<Habit>> = habits

    override fun observeCheckIns(from: LocalDate, to: LocalDate): Flow<List<HabitCheckIn>> =
        completed.map { days ->
            days.filter { (_, date) -> !date.isBefore(from) && !date.isAfter(to) }
                .map { (habitId, date) ->
                    HabitCheckIn(habitId = habitId, date = date, isCompleted = true)
                }
        }

    override suspend fun createHabit(name: String, description: String): Long {
        val id = (habits.value.maxOfOrNull { it.id } ?: 0L) + 1
        habits.value += Habit(id = id, name = name, description = description, position = id.toInt())
        return id
    }

    override suspend fun updateHabit(habit: Habit) {
        habits.value = habits.value.map { if (it.id == habit.id) habit else it }
    }

    override suspend fun archiveHabit(id: Long) {
        habits.value = habits.value.filterNot { it.id == id }
    }

    override suspend fun deleteHabit(id: Long) {
        habits.value = habits.value.filterNot { it.id == id }
        completed.value = completed.value.filterNot { it.first == id }.toSet()
    }

    override suspend fun setCheckIn(habitId: Long, date: LocalDate, isCompleted: Boolean) {
        completed.value = if (isCompleted) {
            completed.value + (habitId to date)
        } else {
            completed.value - (habitId to date)
        }
    }
}
