<?php

namespace Tests\Feature;

use Tests\TestCase;

/**
 * Kept apart from RefreshDatabase tests: it points the default connection at a
 * database that does not exist, which must not leak into the shared test DB.
 */
class ReadinessDatabaseFailureTest extends TestCase
{
    public function test_readiness_fails_when_the_database_is_unreachable(): void
    {
        config([
            'database.connections.broken' => ['driver' => 'sqlite', 'database' => '/nonexistent/dir/db.sqlite'],
            'database.default' => 'broken',
        ]);

        $this->getJson('/ready')
            ->assertStatus(503)
            ->assertJsonPath('status', 'unready')
            ->assertJsonPath('checks.database', 'fail');

        // Liveness must NOT depend on the database (avoids restart storms during a DB outage).
        $this->get('/up')->assertOk();
    }
}
