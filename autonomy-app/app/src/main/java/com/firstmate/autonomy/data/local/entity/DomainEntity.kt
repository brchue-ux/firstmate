package com.firstmate.autonomy.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.firstmate.autonomy.domain.model.DomainStatus
import java.time.Instant

/**
 * Storage row for a personal project.
 *
 * The rich types here are resolved by [com.firstmate.autonomy.data.local.Converters];
 * the column names still name the stored primitive, which is what a reader
 * inspecting the database will actually see.
 */
@Entity(tableName = "domains")
data class DomainEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,
    val title: String,
    val category: String,
    val status: DomainStatus,
    val notes: String,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
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
