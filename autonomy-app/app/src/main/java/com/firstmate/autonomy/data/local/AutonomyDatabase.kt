package com.firstmate.autonomy.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.dao.GoalDao
import com.firstmate.autonomy.data.local.entity.CheckInEntity
import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.data.local.entity.GoalEntity
import com.firstmate.autonomy.data.local.entity.MomentEntity
import com.firstmate.autonomy.data.local.entity.ParticularEntity

/**
 * The single on-device store. Nothing in this app talks to a network, so this
 * database is the whole source of truth.
 *
 * Construction lives in [com.firstmate.autonomy.di.DatabaseModule]; there is no
 * singleton accessor here, because Hilt already guarantees one instance.
 *
 * Version 2 merged projects and habits into [GoalEntity] and introduced the
 * particular and moment levels; see
 * [com.firstmate.autonomy.data.local.migration.MIGRATION_1_2].
 */
@Database(
    entities = [
        GoalEntity::class,
        ParticularEntity::class,
        CheckInEntity::class,
        MomentEntity::class,
        DecisionEntity::class,
    ],
    version = 2,
    exportSchema = true,
)
@TypeConverters(Converters::class)
abstract class AutonomyDatabase : RoomDatabase() {

    abstract fun goalDao(): GoalDao

    abstract fun decisionDao(): DecisionDao

    companion object {
        const val DATABASE_NAME = "autonomy.db"
    }
}
