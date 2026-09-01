package com.firstmate.autonomy.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.SurfaceKind
import java.time.Instant
import java.time.LocalDate

/**
 * Storage row for a goal. Replaces the old `domains` and `habits` tables, which
 * held the same shape of thing under two names.
 */
@Entity(tableName = "goals")
data class GoalEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    val title: String,
    val category: String,
    val status: GoalStatus,
    val notes: String,
    val position: Int,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/**
 * One facet of a goal, and the row check-ins and moments hang off. Cascades
 * from its goal, so deleting a goal never leaves orphan history behind.
 */
@Entity(
    tableName = "particulars",
    foreignKeys = [
        ForeignKey(
            entity = GoalEntity::class,
            parentColumns = ["id"],
            childColumns = ["goal_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("goal_id")],
)
data class ParticularEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    @ColumnInfo(name = "goal_id") val goalId: Long,
    val title: String,
    val kind: SurfaceKind,
    val notes: String,
    val position: Int,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
)

/**
 * One ticked day for one particular.
 *
 * Rows exist only for days that were done, so a missing row reads as "not
 * done" without needing a row per day per particular. The unique index makes
 * an `INSERT OR REPLACE` behave as an upsert, which is what a double-tap on
 * the same day should do.
 */
@Entity(
    tableName = "check_ins",
    foreignKeys = [
        ForeignKey(
            entity = ParticularEntity::class,
            parentColumns = ["id"],
            childColumns = ["particular_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index(value = ["particular_id", "date_epoch_day"], unique = true),
        Index("date_epoch_day"),
    ],
)
data class CheckInEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    @ColumnInfo(name = "particular_id") val particularId: Long,
    @ColumnInfo(name = "date_epoch_day") val date: LocalDate,
)

/**
 * A named moment: one moon.
 *
 * Nothing in the app ever deletes these on your behalf. They are the record of
 * what actually happened, and a bad week is not evidence that it did not.
 */
@Entity(
    tableName = "moments",
    foreignKeys = [
        ForeignKey(
            entity = ParticularEntity::class,
            parentColumns = ["id"],
            childColumns = ["particular_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("particular_id"), Index("date_epoch_day")],
)
data class MomentEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    @ColumnInfo(name = "particular_id") val particularId: Long,
    val label: String,
    @ColumnInfo(name = "date_epoch_day") val date: LocalDate,
    val note: String,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
)
