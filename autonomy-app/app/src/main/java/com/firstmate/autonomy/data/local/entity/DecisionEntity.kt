package com.firstmate.autonomy.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/** Storage row for one journalled decision. */
@Entity(
    tableName = "decisions",
    // The list and the dashboard both sort on this column.
    indices = [Index("date_epoch_day")],
)
data class DecisionEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    val title: String,
    /** Local date as an epoch day, so ordering and range filters stay simple. */
    @ColumnInfo(name = "date_epoch_day") val dateEpochDay: Long,
    /** [com.firstmate.autonomy.domain.model.DecisionCategory] name. */
    val category: String,
    @ColumnInfo(name = "my_preference") val myPreference: String,
    @ColumnInfo(name = "final_choice") val finalChoice: String,
    val reflection: String,
    @ColumnInfo(name = "created_at") val createdAtEpochMilli: Long,
)
