package com.firstmate.autonomy.di

import android.content.Context
import androidx.room.Room
import com.firstmate.autonomy.data.local.AutonomyDatabase
import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.dao.DomainDao
import com.firstmate.autonomy.data.local.dao.HabitDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import java.time.Clock
import javax.inject.Singleton

/**
 * Everything process-scoped: the database, its DAOs, the clock, and the
 * dispatchers.
 *
 * The clock is provided rather than called statically so time is injectable -
 * a test can pin "today" and assert on streaks and date rollover without
 * sleeping or waiting for midnight.
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AutonomyDatabase =
        Room.databaseBuilder(
            context,
            AutonomyDatabase::class.java,
            AutonomyDatabase.DATABASE_NAME,
        ).build()

    @Provides
    fun provideDomainDao(database: AutonomyDatabase): DomainDao = database.domainDao()

    @Provides
    fun provideDecisionDao(database: AutonomyDatabase): DecisionDao = database.decisionDao()

    @Provides
    fun provideHabitDao(database: AutonomyDatabase): HabitDao = database.habitDao()

    @Provides
    @Singleton
    fun provideClock(): Clock = Clock.systemDefaultZone()

    @Provides
    @IoDispatcher
    fun provideIoDispatcher(): CoroutineDispatcher = Dispatchers.IO

    @Provides
    @DefaultDispatcher
    fun provideDefaultDispatcher(): CoroutineDispatcher = Dispatchers.Default
}
