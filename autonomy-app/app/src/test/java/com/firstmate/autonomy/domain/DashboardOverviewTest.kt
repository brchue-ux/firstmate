package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.DashboardOverview
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitWithTodayStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DashboardOverviewTest {

    @Test
    fun `a brand new install has nothing to show`() {
        assertFalse(DashboardOverview().hasAnything)
    }

    @Test
    fun `a finished project alone still counts as something to show`() {
        assertTrue(DashboardOverview(completedDomainCount = 1).hasAnything)
    }

    @Test
    fun `average progress spans the active projects only`() {
        val overview = DashboardOverview(
            activeDomains = listOf(
                domain(id = 1L, completed = 1, total = 2),
                domain(id = 2L, completed = 0, total = 4),
            ),
            completedDomainCount = 3,
        )

        // (0.5 + 0.0) / 2
        assertEquals(0.25f, overview.averageDomainProgress, 0.0001f)
    }

    @Test
    fun `today's tally counts only the habits ticked today`() {
        val overview = DashboardOverview(
            todayHabits = listOf(
                HabitWithTodayStatus(Habit(1L, "Solo time"), isCompletedToday = true),
                HabitWithTodayStatus(Habit(2L, "Practice"), isCompletedToday = false),
                HabitWithTodayStatus(Habit(3L, "Boundary"), isCompletedToday = true),
            ),
        )

        assertEquals(2, overview.todayCompletedCount)
    }

    private fun domain(id: Long, completed: Int, total: Int) = ProjectDomain(
        id = id,
        title = "Project $id",
        category = "Workshop",
        status = DomainStatus.IN_PROGRESS,
        milestones = (0 until total).map {
            Milestone(
                id = it.toLong(),
                domainId = id,
                title = "Step $it",
                isCompleted = it < completed,
            )
        },
    )
}
