package com.firstmate.autonomy.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/** Storage row for a tracked daily habit or boundary. */
@Entity(tableName = "habits")
data class HabitEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    val name: String,
    val description: String,
    @ColumnInfo(name = "is_archived") val isArchived: Boolean,
    val position: Int,
)

/**
 * One completed day for one habit.
 *
 * Rows exist only for days that were ticked, so a missing row reads as "not done".
 * The unique index makes `INSERT OR REPLACE` behave as an upsert per habit-day.
 */
@Entity(
    tableName = "habit_check_ins",
    foreignKeys = [
        ForeignKey(
            entity = HabitEntity::class,
            parentColumns = ["id"],
            childColumns = ["habit_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index(value = ["habit_id", "date_epoch_day"], unique = true),
        Index("date_epoch_day"),
    ],
)
data class HabitCheckInEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    @ColumnInfo(name = "habit_id") val habitId: Long,
    @ColumnInfo(name = "date_epoch_day") val dateEpochDay: Long,
)
