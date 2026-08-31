package com.firstmate.autonomy.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import com.firstmate.autonomy.data.local.entity.DecisionEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface DecisionDao {

    /** Newest decision date first; id breaks ties so ordering is stable. */
    @Query("SELECT * FROM decisions ORDER BY date_epoch_day DESC, id DESC")
    fun observeAll(): Flow<List<DecisionEntity>>

    @Query("SELECT * FROM decisions ORDER BY date_epoch_day DESC, id DESC LIMIT :limit")
    fun observeRecent(limit: Int): Flow<List<DecisionEntity>>

    @Query("SELECT * FROM decisions WHERE id = :id")
    fun observeById(id: Long): Flow<DecisionEntity?>

    @Insert
    suspend fun insert(decision: DecisionEntity): Long

    @Update
    suspend fun update(decision: DecisionEntity)

    @Query("DELETE FROM decisions WHERE id = :id")
    suspend fun deleteById(id: Long)
}
