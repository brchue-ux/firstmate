package com.firstmate.autonomy.domain.usecase

import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.TodayItem
import com.firstmate.autonomy.domain.model.TodayOverview
import com.firstmate.autonomy.domain.repository.DecisionRepository
import com.firstmate.autonomy.domain.repository.GoalRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import java.time.LocalDate
import javax.inject.Inject

/**
 * Assembles the Today tab so its ViewModel stays a thin state holder.
 *
 * Paused and finished goals are left out: Today is a list of things to do
 * now, and a goal you deliberately put down should not keep asking.
 */
class GetTodayOverviewUseCase @Inject constructor(
    private val goalRepository: GoalRepository,
    private val decisionRepository: DecisionRepository,
) {
    operator fun invoke(today: LocalDate): Flow<TodayOverview> = combine(
        goalRepository.observeGoals(),
        decisionRepository.observeRecentDecisions(RECENT_DECISION_COUNT),
    ) { goals, decisions ->
        val live = goals.filter { it.status == GoalStatus.ACTIVE }
        TodayOverview(
            items = live.flatMap { goal ->
                goal.particulars.map { particular ->
                    TodayItem(
                        goalId = goal.id,
                        goalTitle = goal.title,
                        particular = particular,
                        isDoneToday = particular.isCheckedOn(today),
                        condition = particular.condition(today),
                    )
                }
            },
            recentDecisions = decisions,
            goalCount = goals.size,
            momentCount = goals.sumOf { it.momentCount },
        )
    }

    private companion object {
        const val RECENT_DECISION_COUNT = 5
    }
}
