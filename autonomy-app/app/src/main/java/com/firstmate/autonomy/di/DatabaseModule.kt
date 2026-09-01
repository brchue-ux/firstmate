package com.firstmate.autonomy.di

import android.content.Context
import androidx.room.Room
import com.firstmate.autonomy.data.local.AutonomyDatabase
import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.dao.GoalDao
import com.firstmate.autonomy.data.local.migration.MIGRATION_1_2
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
        )
            .addMigrations(MIGRATION_1_2)
            // The migration above is hand-written SQL, and a mismatch with what
            // Room expects would otherwise throw on open - the app would not
            // start at all. Falling back rebuilds an empty file instead, so a
            // wrong migration costs the old history rather than the app.
            .fallbackToDestructiveMigration()
            .build()

    @Provides
    fun provideGoalDao(database: AutonomyDatabase): GoalDao = database.goalDao()

    @Provides
    fun provideDecisionDao(database: AutonomyDatabase): DecisionDao = database.decisionDao()

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
