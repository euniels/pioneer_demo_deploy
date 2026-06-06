<?php

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Cache;

class QueueHealthProbeJob implements ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;
    use SerializesModels;

    public function __construct(public readonly string $probeId)
    {
        $this->onQueue('default');
    }

    public function handle(): void
    {
        $now = now()->toIso8601String();
        Cache::put('pioneer_queue_last_processed_at', $now, now()->addMinutes(10));
        Cache::put('pioneer_queue_probe_'.$this->probeId, $now, now()->addMinutes(5));
    }
}
