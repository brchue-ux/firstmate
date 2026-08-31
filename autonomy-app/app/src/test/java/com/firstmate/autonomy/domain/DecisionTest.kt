package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class DecisionTest {

    @Test
    fun `matching preference and choice count as following your own preference`() {
        val decision = decision(
            preference = "Keep Sunday morning free",
            choice = "  keep sunday morning free  ",
        )

        assertTrue(decision.followedOwnPreference)
    }

    @Test
    fun `a different final choice does not count`() {
        val decision = decision(preference = "The 4-channel scope", choice = "The 2-channel scope")

        assertFalse(decision.followedOwnPreference)
    }

    @Test
    fun `two blank fields are not treated as agreement`() {
        assertFalse(decision(preference = "", choice = "").followedOwnPreference)
    }

    @Test
    fun `reflection is optional and reported as pending while blank`() {
        assertFalse(decision(reflection = "   ").hasReflection)
        assertTrue(decision(reflection = "Glad about it.").hasReflection)
    }

    @Test
    fun `an unknown stored category falls back to personal`() {
        assertTrue(DecisionCategory.fromStorage("SOMETHING_ELSE") == DecisionCategory.PERSONAL)
    }

    private fun decision(
        preference: String = "a",
        choice: String = "a",
        reflection: String = "",
    ) = Decision(
        id = 1L,
        title = "Test decision",
        date = LocalDate.of(2026, 3, 12),
        myPreference = preference,
        finalChoice = choice,
        reflection = reflection,
    )
}
