package com.firstmate.autonomy.di

import com.firstmate.autonomy.data.repository.DecisionRepositoryImpl
import com.firstmate.autonomy.data.repository.GoalRepositoryImpl
import com.firstmate.autonomy.domain.repository.DecisionRepository
import com.firstmate.autonomy.domain.repository.GoalRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Binds each domain-layer contract to its Room-backed implementation.
 *
 * `@Binds` rather than `@Provides`: the implementations already have
 * `@Inject` constructors, so Dagger only needs to be told which interface they
 * satisfy - no factory method is generated, and swapping in a fake for a test
 * means replacing this one module.
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {

    @Binds
    @Singleton
    abstract fun bindGoalRepository(impl: GoalRepositoryImpl): GoalRepository

    @Binds
    @Singleton
    abstract fun bindDecisionRepository(impl: DecisionRepositoryImpl): DecisionRepository
}
