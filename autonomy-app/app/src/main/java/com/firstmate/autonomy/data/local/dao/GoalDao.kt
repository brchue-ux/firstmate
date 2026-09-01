package com.firstmate.autonomy.data.local.dao

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update
import com.firstmate.autonomy.data.local.entity.CheckInEntity
import com.firstmate.autonomy.data.local.entity.GoalEntity
import com.firstmate.autonomy.data.local.entity.MomentEntity
import com.firstmate.autonomy.data.local.entity.ParticularEntity
import com.firstmate.autonomy.data.local.relation.GoalWithParticulars
import kotlinx.coroutines.flow.Flow

@Dao
interface GoalDao {

    @Transaction
    @Query("SELECT * FROM goals ORDER BY position ASC, id ASC")
    fun observeGoals(): Flow<List<GoalWithParticulars>>

    @Transaction
    @Query("SELECT * FROM goals WHERE id = :goalId")
    fun observeGoal(goalId: Long): Flow<GoalWithParticulars?>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertGoal(goal: GoalEntity): Long

    @Update
    suspend fun updateGoal(goal: GoalEntity)

    @Query("DELETE FROM goals WHERE id = :goalId")
    suspend fun deleteGoal(goalId: Long)

    @Query("SELECT IFNULL(MAX(position), -1) + 1 FROM goals")
    suspend fun nextGoalPosition(): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertParticular(particular: ParticularEntity): Long

    @Update
    suspend fun updateParticular(particular: ParticularEntity)

    @Query("DELETE FROM particulars WHERE id = :particularId")
    suspend fun deleteParticular(particularId: Long)

    @Query("SELECT IFNULL(MAX(position), -1) + 1 FROM particulars WHERE goal_id = :goalId")
    suspend fun nextParticularPosition(goalId: Long): Int

    /**
     * Ticking a day is an upsert on the unique (particular, day) index, so
     * tapping twice in one day cannot produce two rows.
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertCheckIn(checkIn: CheckInEntity)

    @Query(
        "DELETE FROM check_ins WHERE particular_id = :particularId " +
            "AND date_epoch_day = :epochDay",
    )
    suspend fun deleteCheckIn(particularId: Long, epochDay: Long)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMoment(moment: MomentEntity): Long

    @Delete
    suspend fun deleteMoment(moment: MomentEntity)

    @Query("DELETE FROM moments WHERE id = :momentId")
    suspend fun deleteMomentById(momentId: Long)
}
