package com.firstmate.autonomy.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.dao.DomainDao
import com.firstmate.autonomy.data.local.dao.HabitDao
import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.data.local.entity.DomainEntity
import com.firstmate.autonomy.data.local.entity.HabitCheckInEntity
import com.firstmate.autonomy.data.local.entity.HabitEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity

/**
 * The single on-device store. Nothing in this app talks to a network,
 * so this database is the whole source of truth.
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
abstract class AutonomyDatabase : RoomDatabase() {

    abstract fun domainDao(): DomainDao

    abstract fun decisionDao(): DecisionDao

    abstract fun habitDao(): HabitDao

    companion object {
        private const val DATABASE_NAME = "autonomy.db"

        @Volatile
        private var instance: AutonomyDatabase? = null

        fun getInstance(context: Context): AutonomyDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        private fun build(context: Context): AutonomyDatabase =
            Room.databaseBuilder(context, AutonomyDatabase::class.java, DATABASE_NAME)
                .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
                .build()
    }
}
