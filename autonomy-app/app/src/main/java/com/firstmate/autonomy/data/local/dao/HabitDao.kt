package com.firstmate.autonomy.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.firstmate.autonomy.data.local.entity.HabitCheckInEntity
import com.firstmate.autonomy.data.local.entity.HabitEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface HabitDao {

    @Query("SELECT * FROM habits WHERE is_archived = 0 ORDER BY position ASC, id ASC")
    fun observeActive(): Flow<List<HabitEntity>>

    @Query("SELECT COALESCE(MAX(position), -1) + 1 FROM habits")
    suspend fun nextPosition(): Int

    @Insert
    suspend fun insert(habit: HabitEntity): Long

    @Update
    suspend fun update(habit: HabitEntity)

    @Query("UPDATE habits SET is_archived = 1 WHERE id = :id")
    suspend fun archive(id: Long)

    @Query("DELETE FROM habits WHERE id = :id")
    suspend fun deleteById(id: Long)

    // --- Check-ins --------------------------------------------------------

    @Query(
        """
        SELECT * FROM habit_check_ins
        WHERE date_epoch_day BETWEEN :fromEpochDay AND :toEpochDay
        """,
    )
    fun observeCheckInsBetween(
        fromEpochDay: Long,
        toEpochDay: Long,
    ): Flow<List<HabitCheckInEntity>>

    /** The unique (habit, day) index turns this into an upsert. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertCheckIn(checkIn: HabitCheckInEntity)

    /** Un-ticking removes the row, keeping the table sparse. */
    @Query("DELETE FROM habit_check_ins WHERE habit_id = :habitId AND date_epoch_day = :epochDay")
    suspend fun deleteCheckIn(habitId: Long, epochDay: Long)
}
