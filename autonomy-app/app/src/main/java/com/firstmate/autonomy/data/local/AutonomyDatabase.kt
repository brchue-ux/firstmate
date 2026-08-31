package com.firstmate.autonomy.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.dao.DomainDao
import com.firstmate.autonomy.data.local.dao.HabitDao
import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.data.local.entity.DomainEntity
import com.firstmate.autonomy.data.local.entity.HabitCheckInEntity
import com.firstmate.autonomy.data.local.entity.HabitEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity

/**
 * The single on-device store. Nothing in this app talks to a network, so this
 * database is the whole source of truth.
 *
 * Construction lives in [com.firstmate.autonomy.di.DatabaseModule]; there is no
 * singleton accessor here, because Hilt already guarantees one instance.
 */
@Database(
    entities = [
        DomainEntity::class,
        MilestoneEntity::class,
        DecisionEntity::class,
        HabitEntity::class,
        HabitCheckInEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
@TypeConverters(Converters::class)
abstract class AutonomyDatabase : RoomDatabase() {

    abstract fun domainDao(): DomainDao

    abstract fun decisionDao(): DecisionDao

    abstract fun habitDao(): HabitDao

    companion object {
        const val DATABASE_NAME = "autonomy.db"
    }
}
