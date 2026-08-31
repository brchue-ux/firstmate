package com.firstmate.autonomy.di

import android.content.Context
import com.firstmate.autonomy.data.local.AutonomyDatabase
import com.firstmate.autonomy.data.repository.DecisionRepositoryImpl
import com.firstmate.autonomy.data.repository.DomainRepositoryImpl
import com.firstmate.autonomy.data.repository.HabitRepositoryImpl
import com.firstmate.autonomy.domain.repository.DecisionRepository
import com.firstmate.autonomy.domain.repository.DomainRepository
import com.firstmate.autonomy.domain.repository.HabitRepository
import com.firstmate.autonomy.domain.usecase.GetDashboardOverviewUseCase
import com.firstmate.autonomy.domain.usecase.GetHabitConsistencyUseCase
import java.time.Clock

/**
 * Hand-rolled dependency container.
 *
 * The graph is small and entirely local, so a constructor-injection container
 * beats pulling in an annotation-processing DI framework: it is readable,
 * builds fast, and is trivially swappable in tests.
 */
interface AppContainer {
    val clock: Clock
    val domainRepository: DomainRepository
    val decisionRepository: DecisionRepository
    val habitRepository: HabitRepository
    val getHabitConsistency: GetHabitConsistencyUseCase
    val getDashboardOverview: GetDashboardOverviewUseCase
}

/** Production graph, backed by the Room database. */
class DefaultAppContainer(
    context: Context,
    override val clock: Clock = Clock.systemDefaultZone(),
) : AppContainer {

    private val database = AutonomyDatabase.getInstance(context)

    override val domainRepository: DomainRepository by lazy {
        DomainRepositoryImpl(database.domainDao(), clock)
    }

    override val decisionRepository: DecisionRepository by lazy {
        DecisionRepositoryImpl(database.decisionDao(), clock)
    }

    override val habitRepository: HabitRepository by lazy {
        HabitRepositoryImpl(database.habitDao())
    }

    override val getHabitConsistency: GetHabitConsistencyUseCase by lazy {
        GetHabitConsistencyUseCase(habitRepository)
    }

    override val getDashboardOverview: GetDashboardOverviewUseCase by lazy {
        GetDashboardOverviewUseCase(
            domainRepository = domainRepository,
            decisionRepository = decisionRepository,
            getHabitConsistency = getHabitConsistency,
        )
    }
}
