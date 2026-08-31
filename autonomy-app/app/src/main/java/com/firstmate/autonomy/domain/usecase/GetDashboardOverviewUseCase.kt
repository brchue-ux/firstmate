package com.firstmate.autonomy.domain.usecase

import com.firstmate.autonomy.domain.model.DashboardOverview
import com.firstmate.autonomy.domain.model.HabitWithTodayStatus
import com.firstmate.autonomy.domain.repository.DecisionRepository
import com.firstmate.autonomy.domain.repository.DomainRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import java.time.LocalDate

/**
 * Assembles the home screen from the three feature repositories so the
 * dashboard ViewModel stays a thin state holder.
 */
class GetDashboardOverviewUseCase(
    private val domainRepository: DomainRepository,
    private val decisionRepository: DecisionRepository,
    private val getHabitConsistency: GetHabitConsistencyUseCase,
) {
    operator fun invoke(today: LocalDate): Flow<DashboardOverview> = combine(
        domainRepository.observeDomains(),
        decisionRepository.observeRecentDecisions(RECENT_DECISION_COUNT),
        getHabitConsistency(today = today, windowDays = WEEK_DAYS),
    ) { domains, decisions, consistency ->
        val (active, completed) = domains.partition { it.status.isActive }
        DashboardOverview(
            activeDomains = active,
            completedDomainCount = completed.size,
            recentDecisions = decisions,
            todayHabits = consistency.map {
                HabitWithTodayStatus(
                    habit = it.habit,
                    isCompletedToday = it.days.lastOrNull()?.isCompleted == true,
                )
            },
            weeklyHabitRate = consistency.weeklyRate(),
        )
    }

    /** Completion across every habit-day in the window, not an average of averages. */
    private fun List<com.firstmate.autonomy.domain.model.HabitConsistency>.weeklyRate(): Float {
        val totalDays = sumOf { it.days.size }
        if (totalDays == 0) return 0f
        return sumOf { it.completedCount }.toFloat() / totalDays
    }

    private companion object {
        const val RECENT_DECISION_COUNT = 5
        const val WEEK_DAYS = 7
    }
}
