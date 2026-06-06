<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

class OptimizeFleetApiResponses
{
    public function handle(Request $request, Closure $next): Response
    {
        /** @var Response $response */
        $response = $next($request);

        if (! $this->shouldOptimize($request, $response)) {
            return $response;
        }

        $content = (string) $response->getContent();
        $etag = '"'.sha1($this->stableEtagContent($content)).'"';
        $lastModified = gmdate('D, d M Y H:i:s', time()).' GMT';

        if ($this->etagMatches($request->getETags(), $etag)) {
            $notModified = response('', 304);
            $notModified->headers->set('ETag', $etag);
            $notModified->headers->set('Last-Modified', $lastModified);
            $notModified->headers->set('Cache-Control', 'private, must-revalidate');
            $notModified->headers->set('Vary', 'Accept-Encoding');

            return $notModified;
        }

        $response->headers->set('ETag', $etag);
        $response->headers->set('Last-Modified', $lastModified);
        $response->headers->set('Cache-Control', 'private, must-revalidate');
        $response->headers->set('Vary', 'Accept-Encoding');

        if ($this->clientAcceptsGzip($request) && $this->isJsonResponse($response)) {
            $gzipped = gzencode($content, 6);
            if ($gzipped !== false) {
                $response->setContent($gzipped);
                $response->headers->set('Content-Encoding', 'gzip');
                $response->headers->set('Content-Length', (string) strlen($gzipped));
            }
        }

        return $response;
    }

    private function shouldOptimize(Request $request, Response $response): bool
    {
        if (! $request->isMethod('GET') || ! $request->is('api/fleet/*')) {
            return false;
        }

        if ($response->isRedirection() || $response->getStatusCode() !== 200) {
            return false;
        }

        if (str_starts_with((string) $response->headers->get('Content-Type'), 'text/event-stream')) {
            return false;
        }

        if ($response->headers->has('Content-Encoding')) {
            return false;
        }

        $content = $response->getContent();

        return is_string($content) && $content !== '';
    }

    /**
     * @param  array<int, string>  $ifNoneMatch
     */
    private function etagMatches(array $ifNoneMatch, string $etag): bool
    {
        if ($ifNoneMatch === []) {
            return false;
        }

        $candidates = array_map('trim', $ifNoneMatch);
        $normalizedEtag = $this->normalizeEtag($etag);

        foreach ($candidates as $candidate) {
            if ($candidate === '*' || $this->normalizeEtag($candidate) === $normalizedEtag) {
                return true;
            }
        }

        return false;
    }

    private function clientAcceptsGzip(Request $request): bool
    {
        $accepted = strtolower((string) $request->headers->get('Accept-Encoding', ''));

        return str_contains($accepted, 'gzip');
    }

    private function isJsonResponse(Response $response): bool
    {
        $contentType = strtolower((string) $response->headers->get('Content-Type', ''));

        return str_contains($contentType, 'application/json');
    }

    private function stableEtagContent(string $content): string
    {
        $decoded = json_decode($content, true);
        if (! is_array($decoded)) {
            return $content;
        }

        if (isset($decoded['meta']) && is_array($decoded['meta'])) {
            unset(
                $decoded['meta']['requestId'],
                $decoded['meta']['elapsedMs'],
                $decoded['meta']['generatedAt'],
                $decoded['meta']['snapshotAgeSeconds']
            );
        }

        return json_encode($decoded, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?: $content;
    }

    private function normalizeEtag(string $etag): string
    {
        $trimmed = trim($etag);
        $trimmed = preg_replace('/^W\//i', '', $trimmed) ?? $trimmed;

        return trim(stripslashes($trimmed), "\" \t\n\r\0\x0B");
    }
}
