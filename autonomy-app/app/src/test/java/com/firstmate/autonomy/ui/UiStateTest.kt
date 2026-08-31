package com.firstmate.autonomy.ui

import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.asUiState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStateTest {

    @Test
    fun `loading is emitted before the first value`() = runTest {
        val source = MutableStateFlow(listOf("a"))

        val emissions = source.asUiState().take(2).toList()

        assertEquals(UiState.Loading, emissions[0])
        assertEquals(UiState.Success(listOf("a")), emissions[1])
    }

    @Test
    fun `a throwing source becomes an Error rather than propagating`() = runTest {
        val boom = IllegalStateException("database unreadable")
        val source = flow<String> { throw boom }

        val emissions = source.asUiState("Could not read.").toList()

        assertEquals(UiState.Loading, emissions[0])
        val error = emissions[1] as UiState.Error
        assertEquals("Could not read.", error.message)
        assertEquals(boom, error.cause)
    }

    @Test
    fun `dataOrNull unwraps only the success case`() {
        assertEquals(7, UiState.Success(7).dataOrNull)
        assertNull(UiState.Loading.dataOrNull)
        assertNull(UiState.Error("nope").dataOrNull)
    }

    @Test
    fun `loading is emitted once, not before every value`() = runTest {
        val emissions = flowOf(0, 1, 2).asUiState().toList()

        assertEquals(4, emissions.size)
        assertEquals(UiState.Loading, emissions.first())
        assertTrue(emissions.drop(1).all { it is UiState.Success })
        assertEquals(listOf(0, 1, 2), emissions.drop(1).map { it.dataOrNull })
    }
}
