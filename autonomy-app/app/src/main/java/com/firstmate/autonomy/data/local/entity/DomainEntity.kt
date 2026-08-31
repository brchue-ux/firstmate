package com.firstmate.autonomy.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Storage row for a personal project.
 *
 * Times are plain epoch primitives rather than `java.time` types so the schema is
 * obvious in SQL and no type converters are needed for range queries.
 */
@Entity(tableName = "domains")
data class DomainEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    val title: String,
    val category: String,
    /** [com.firstmate.autonomy.domain.model.DomainStatus] name. */
    val status: String,
    val notes: String,
    @ColumnInfo(name = "created_at") val createdAtEpochMilli: Long,
    @ColumnInfo(name = "updated_at") val updatedAtEpochMilli: Long,
)

/**
 * A milestone belongs to exactly one domain and dies with it
 * ([ForeignKey.CASCADE]), so deleting a project never leaves orphan rows.
 */
@Entity(
    tableName = "milestones",
    foreignKeys = [
        ForeignKey(
            entity = DomainEntity::class,
            parentColumns = ["id"],
            childColumns = ["domain_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("domain_id")],
)
data class MilestoneEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    @ColumnInfo(name = "domain_id") val domainId: Long,
    val title: String,
    @ColumnInfo(name = "is_completed") val isCompleted: Boolean,
    val position: Int,
)
