package com.firstmate.autonomy.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Transaction
import com.firstmate.autonomy.data.local.entity.DomainEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity
import com.firstmate.autonomy.data.local.relation.DomainWithMilestones
import kotlinx.coroutines.flow.Flow

@Dao
interface DomainDao {

    @Transaction
    @Query("SELECT * FROM domains ORDER BY updated_at DESC")
    fun observeAll(): Flow<List<DomainWithMilestones>>

    @Transaction
    @Query("SELECT * FROM domains WHERE id = :id")
    fun observeById(id: Long): Flow<DomainWithMilestones?>

    @Insert
    suspend fun insert(domain: DomainEntity): Long

    /**
     * Field-level update rather than `@Update`, so an edit never has to read the
     * whole row first and can bump `updated_at` in the same statement.
     */
    @Query(
        """
        UPDATE domains
        SET title = :title,
            category = :category,
            status = :status,
            notes = :notes,
            updated_at = :updatedAtEpochMilli
        WHERE id = :id
        """,
    )
    suspend fun update(
        id: Long,
        title: String,
        category: String,
        status: String,
        notes: String,
        updatedAtEpochMilli: Long,
    )

    @Query("UPDATE domains SET updated_at = :updatedAtEpochMilli WHERE id = :id")
    suspend fun touch(id: Long, updatedAtEpochMilli: Long)

    @Query("DELETE FROM domains WHERE id = :id")
    suspend fun deleteById(id: Long)

    // --- Milestones -------------------------------------------------------

    @Insert
    suspend fun insertMilestone(milestone: MilestoneEntity): Long

    @Query("SELECT COALESCE(MAX(position), -1) + 1 FROM milestones WHERE domain_id = :domainId")
    suspend fun nextMilestonePosition(domainId: Long): Int

    @Query("SELECT domain_id FROM milestones WHERE id = :milestoneId")
    suspend fun domainIdForMilestone(milestoneId: Long): Long?

    @Query("UPDATE milestones SET is_completed = :isCompleted WHERE id = :milestoneId")
    suspend fun setMilestoneCompleted(milestoneId: Long, isCompleted: Boolean)

    @Query("UPDATE milestones SET title = :title WHERE id = :milestoneId")
    suspend fun renameMilestone(milestoneId: Long, title: String)

    @Query("DELETE FROM milestones WHERE id = :milestoneId")
    suspend fun deleteMilestone(milestoneId: Long)
}
