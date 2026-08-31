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
    // The list and the dashboard both sort on this column.
    indices = [Index("date_epoch_day")],
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
)
