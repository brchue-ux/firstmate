package com.firstmate.autonomy.data

import com.firstmate.autonomy.data.local.Converters
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.DomainStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

/**
 * These guard the on-disk format. A change here silently rewrites how every
 * existing row is interpreted, so the encodings are asserted literally rather
 * than only round-tripped.
 */
class ConvertersTest {

    private val converters = Converters()

    @Test
    fun `dates are stored as epoch days`() {
        val date = LocalDate.of(2026, 3, 12)

        assertEquals(date.toEpochDay(), converters.localDateToEpochDay(date))
        assertEquals(date, converters.epochDayToLocalDate(date.toEpochDay()))
    }

    @Test
    fun `dates before the epoch round-trip`() {
        val date = LocalDate.of(1963, 11, 22)

        assertEquals(date, converters.epochDayToLocalDate(converters.localDateToEpochDay(date)))
    }

    @Test
    fun `timestamps are stored as epoch millis`() {
        val instant = Instant.ofEpochMilli(1_772_000_000_000L)

        assertEquals(1_772_000_000_000L, converters.instantToEpochMilli(instant))
        assertEquals(instant, converters.epochMilliToInstant(1_772_000_000_000L))
    }

    @Test
    fun `enums are stored by name`() {
        assertEquals("IN_PROGRESS", converters.domainStatusToName(DomainStatus.IN_PROGRESS))
        assertEquals("FAMILY_DYNAMICS", converters.decisionCategoryToName(DecisionCategory.FAMILY_DYNAMICS))
    }

    @Test
    fun `an unknown stored enum degrades instead of throwing inside a cursor`() {
        assertEquals(DomainStatus.PLANNING, converters.nameToDomainStatus("ABANDONED"))
        assertEquals(DecisionCategory.PERSONAL, converters.nameToDecisionCategory("SOMETHING_NEW"))
    }

    @Test
    fun `nulls pass straight through in both directions`() {
        assertNull(converters.localDateToEpochDay(null))
        assertNull(converters.epochDayToLocalDate(null))
        assertNull(converters.instantToEpochMilli(null))
        assertNull(converters.epochMilliToInstant(null))
        assertNull(converters.domainStatusToName(null))
        assertNull(converters.nameToDomainStatus(null))
    }
}
