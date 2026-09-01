package com.firstmate.autonomy.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.firstmate.autonomy.domain.model.DecisionCategory
import java.time.Instant
import java.time.LocalDate

/** Storage row for one journalled decision. */
@Entity(
    tableName = "decisions",
    // The list and Today both sort on the date; the goal index backs the
    // "decisions about this goal" lookup the goal readout makes.
    indices = [Index("date_epoch_day"), Index("goal_id")],
)
data class DecisionEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    val title: String,
    /** Stored as an epoch day, so ordering and range filters stay plain SQL. */
    @ColumnInfo(name = "date_epoch_day") val date: LocalDate,
    val category: DecisionCategory,
    @ColumnInfo(name = "my_preference") val myPreference: String,
    @ColumnInfo(name = "final_choice") val finalChoice: String,
    val reflection: String,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    /**
     * The goal this decision was about, if any.
     *
     * Deliberately not a foreign key: SQLite cannot add one to an existing
     * table without rebuilding it, and a decision outliving the goal it was
     * about is a real case anyway - you decided to stop doing something. The
     * repository clears the reference when a goal is deleted.
     */
    @ColumnInfo(name = "goal_id") val goalId: Long? = null,
)
