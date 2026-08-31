package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.usecase.GetHabitConsistencyUseCase
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class GetHabitConsistencyUseCaseTest {

    private val today = LocalDate.of(2026, 3, 12)
    private val habit = Habit(id = 1L, name = "Solo time")

    @Test
    fun `every day in the window is present even though storage is sparse`() = runTest {
        val useCase = GetHabitConsistencyUseCase(
            FakeHabitRepository(
                initialHabits = listOf(habit),
                initialCompletedDays = setOf(1L to today, 1L to today.minusDays(2)),
            ),
        )

        val result = useCase(today = today, windowDays = 7).first().single()

        assertEquals(7, result.days.size)
        assertEquals(today.minusDays(6), result.days.first().date)
        assertEquals(today, result.days.last().date)
        assertEquals(2, result.completedCount)
    }

    @Test
    fun `check-ins outside the window are ignored`() = runTest {
        val useCase = GetHabitConsistencyUseCase(
            FakeHabitRepository(
                initialHabits = listOf(habit),
                initialCompletedDays = setOf(1L to today.minusDays(30)),
            ),
        )

        val result = useCase(today = today, windowDays = 7).first().single()

        assertEquals(0, result.completedCount)
        assertTrue(result.days.none { it.isCompleted })
    }

    @Test
    fun `streak counts back from the most recent day only`() = runTest {
        val useCase = GetHabitConsistencyUseCase(
            FakeHabitRepository(
                initialHabits = listOf(habit),
                initialCompletedDays = setOf(
                    1L to today,
                    1L to today.minusDays(1),
                    // Gap on day 2, so the streak stops at three.
                    1L to today.minusDays(2),
                    1L to today.minusDays(4),
                ),
            ),
        )

        val result = useCase(today = today, windowDays = 7).first().single()

        assertEquals(3, result.currentStreak)
        assertEquals(4, result.completedCount)
        assertEquals(57, result.ratePercent)
    }

    @Test
    fun `a habit with no check-ins still produces a full empty window`() = runTest {
        val useCase = GetHabitConsistencyUseCase(
            FakeHabitRepository(initialHabits = listOf(habit)),
        )

        val result = useCase(today = today, windowDays = 30).first().single()

        assertEquals(30, result.days.size)
        assertEquals(0, result.currentStreak)
        assertEquals(0, result.ratePercent)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a non-positive window is rejected`() = runTest {
        GetHabitConsistencyUseCase(FakeHabitRepository())(today = today, windowDays = 0)
    }
}
