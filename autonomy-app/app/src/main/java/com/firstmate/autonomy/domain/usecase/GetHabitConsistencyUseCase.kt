package com.firstmate.autonomy.domain.usecase

import com.firstmate.autonomy.domain.model.DayStatus
import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitConsistency
import com.firstmate.autonomy.domain.repository.HabitRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import java.time.LocalDate

/**
 * Turns sparse check-in rows into a dense, gap-free day series per habit.
 *
 * The database only stores days the user actually answered; every screen that
 * draws a strip or a percentage needs one entry per day in the window, so the
 * densifying happens here rather than in each ViewModel.
 */
class GetHabitConsistencyUseCase(
    private val habitRepository: HabitRepository,
) {
    /**
     * @param windowDays number of days ending at [today], inclusive.
     */
    operator fun invoke(
        today: LocalDate,
        windowDays: Int,
    ): Flow<List<HabitConsistency>> {
        require(windowDays > 0) { "windowDays must be positive, was $windowDays" }
        val from = today.minusDays((windowDays - 1).toLong())
        return combine(
            habitRepository.observeHabits(),
            habitRepository.observeCheckIns(from = from, to = today),
        ) { habits, checkIns ->
            // (habitId, date) -> completed, for O(1) lookup while densifying.
            val completedKeys: Set<Pair<Long, LocalDate>> = checkIns
                .filter { it.isCompleted }
                .map { it.habitId to it.date }
                .toSet()
            val window: List<LocalDate> = (0 until windowDays).map { offset ->
                from.plusDays(offset.toLong())
            }
            habits.map { habit -> habit.toConsistency(window, completedKeys) }
        }
    }

    private fun Habit.toConsistency(
        window: List<LocalDate>,
        completedKeys: Set<Pair<Long, LocalDate>>,
    ) = HabitConsistency(
        habit = this,
        days = window.map { date ->
            DayStatus(date = date, isCompleted = (id to date) in completedKeys)
        },
    )
}
