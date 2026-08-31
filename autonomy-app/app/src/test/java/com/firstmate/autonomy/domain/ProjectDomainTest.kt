package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectDomainTest {

    @Test
    fun `progress is the completed fraction of milestones`() {
        val domain = domainWith(completed = 3, total = 5)

        assertEquals(0.6f, domain.progress, TOLERANCE)
        assertEquals(60, domain.progressPercent)
    }

    @Test
    fun `a domain with no milestones reads as zero while it is still open`() {
        val domain = domainWith(completed = 0, total = 0, status = DomainStatus.IN_PROGRESS)

        assertEquals(0f, domain.progress, TOLERANCE)
    }

    @Test
    fun `a completed domain with no milestones reads as fully done`() {
        val domain = domainWith(completed = 0, total = 0, status = DomainStatus.COMPLETED)

        assertEquals(1f, domain.progress, TOLERANCE)
    }

    @Test
    fun `an unknown stored status falls back to planning rather than throwing`() {
        assertEquals(DomainStatus.PLANNING, DomainStatus.fromStorage("ABANDONED"))
        assertEquals(DomainStatus.COMPLETED, DomainStatus.fromStorage("COMPLETED"))
    }

    private fun domainWith(
        completed: Int,
        total: Int,
        status: DomainStatus = DomainStatus.IN_PROGRESS,
    ) = ProjectDomain(
        id = 1L,
        title = "Test project",
        category = "Workshop",
        status = status,
        milestones = (0 until total).map { index ->
            Milestone(
                id = index.toLong(),
                domainId = 1L,
                title = "Step $index",
                isCompleted = index < completed,
                position = index,
            )
        },
    )

    private companion object {
        const val TOLERANCE = 0.0001f
    }
}
