package com.firstmate.autonomy.data.local

import androidx.room.TypeConverter
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.SurfaceKind
import java.time.Instant
import java.time.LocalDate

/**
 * Lets entities declare real types - [LocalDate], [Instant], enums - while the
 * columns stay the primitives SQLite sorts and range-filters natively.
 *
 * Dates are stored as epoch days, timestamps as epoch millis, and enums as their
 * `name`, which is what the version 2 migration writes.
 *
 * Enum reads go through the tolerant `fromStorage` lookups rather than
 * `valueOf`, so a value written by a newer build - or a corrupted row - degrades
 * to a sane default instead of throwing inside a database cursor.
 */
class Converters {

    @TypeConverter
    fun localDateToEpochDay(value: LocalDate?): Long? = value?.toEpochDay()

    @TypeConverter
    fun epochDayToLocalDate(value: Long?): LocalDate? = value?.let(LocalDate::ofEpochDay)

    @TypeConverter
    fun instantToEpochMilli(value: Instant?): Long? = value?.toEpochMilli()

    @TypeConverter
    fun epochMilliToInstant(value: Long?): Instant? = value?.let(Instant::ofEpochMilli)

    @TypeConverter
    fun goalStatusToName(value: GoalStatus?): String? = value?.name

    @TypeConverter
    fun nameToGoalStatus(value: String?): GoalStatus? = value?.let { stored ->
        GoalStatus.entries.firstOrNull { it.name.equals(stored, ignoreCase = true) }
            ?: GoalStatus.ACTIVE
    }

    @TypeConverter
    fun surfaceKindToName(value: SurfaceKind?): String? = value?.name

    @TypeConverter
    fun nameToSurfaceKind(value: String?): SurfaceKind? = value?.let { stored ->
        SurfaceKind.entries.firstOrNull { it.name.equals(stored, ignoreCase = true) }
            ?: SurfaceKind.ROCK
    }

    @TypeConverter
    fun decisionCategoryToName(value: DecisionCategory?): String? = value?.name

    @TypeConverter
    fun nameToDecisionCategory(value: String?): DecisionCategory? =
        value?.let(DecisionCategory::fromStorage)
}
