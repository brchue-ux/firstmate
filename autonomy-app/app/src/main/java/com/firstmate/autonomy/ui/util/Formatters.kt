package com.firstmate.autonomy.ui.util

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

private val fullDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM yyyy", Locale.getDefault())

private val shortDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())

/** "12 Mar 2026". */
fun LocalDate.formatFull(): String = format(fullDateFormatter)

/** "12 Mar", dropping the year for compact list rows. */
fun LocalDate.formatShort(): String = format(shortDateFormatter)

/** "Today" / "Yesterday" / "12 Mar" - the phrasing a journal list wants. */
fun LocalDate.formatRelative(today: LocalDate): String = when (this) {
    today -> "Today"
    today.minusDays(1) -> "Yesterday"
    else -> {
        val days = ChronoUnit.DAYS.between(this, today)
        if (days in 2..6) "$days days ago" else formatShort()
    }
}

/** Single-letter weekday for the habit strip: M T W T F S S. */
fun LocalDate.weekdayInitial(): String =
    dayOfWeek.getDisplayName(TextStyle.NARROW, Locale.getDefault())

/** "Mon 12". */
fun LocalDate.weekdayAndDay(): String {
    val weekday = dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())
    return "$weekday $dayOfMonth"
}
