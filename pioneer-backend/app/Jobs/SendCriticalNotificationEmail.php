<?php

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;

class SendCriticalNotificationEmail implements ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;
    use SerializesModels;

    public int $tries = 3;

    /**
     * @param  array<int, string>  $recipients
     * @param  array<string, mixed>  $context
     */
    public function __construct(
        public array $recipients,
        public string $subject,
        public string $body,
        public array $context = [],
    ) {
        $this->onQueue('notifications');
    }

    public function handle(): void
    {
        $recipients = collect($this->recipients)
            ->map(fn (string $email): string => strtolower(trim($email)))
            ->filter(fn (string $email): bool => filter_var($email, FILTER_VALIDATE_EMAIL) !== false)
            ->unique()
            ->values();

        if ($recipients->isEmpty()) {
            return;
        }

        foreach ($recipients as $recipient) {
            Mail::raw($this->body, function ($message) use ($recipient): void {
                $message->to($recipient)
                    ->subject($this->subject);
            });
        }

        Log::channel('notifications')->info('pioneerpath.critical_email.sent', [
            'recipientCount' => $recipients->count(),
            'subject' => Str::limit($this->subject, 120, ''),
            'context' => $this->context,
        ]);
    }
}
