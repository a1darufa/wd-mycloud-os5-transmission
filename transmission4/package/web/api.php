<?php
// api.php — the server side of Transmission 4's settings page. It reads the
// app's state and hands checked changes to ctl.sh; app-api.php explains how
// requests are guarded. Actions (JSON POST): "status", "save".

declare(strict_types=1);

require __DIR__ . '/app-api.php';

const TR_MIN_PASSWORD = 8;
const TR_MAX_PASSWORD = 128;
const TR_MAX_PATTERNS = 32;

api_guard('transmission4');
$request = api_read_request();

switch ($request['action'] ?? '') {
    case 'status':
        api_reply(['ok' => true, 'status' => transmission_status()]);
        break;
    case 'save':
        transmission_save($request);
        break;
    default:
        api_fail(400, 'Unknown action.');
}

function transmission_status(): array
{
    [$code, $output] = api_run_ctl('web-status');
    if ($code !== 0) {
        api_fail(500, "Couldn't read Transmission's state on the NAS.");
    }
    $status = ['allowed' => [], 'apply' => ['state' => 'idle', 'message' => '', 'time' => '']];
    foreach (api_output_pairs($output) as [$key, $value]) {
        switch ($key) {
            case 'daemon':
                $status['daemon'] = $value;
                break;
            case 'should_run':
            case 'set_up':
            case 'wd_running':
            case 'initial_password':
            case 'password_set':
                $status[$key] = $value === '1';
                break;
            case 'port':
                $status['port'] = (int) $value;
                break;
            case 'username_json':
                $username = json_decode($value);
                $status['username'] = is_string($username) ? $username : '';
                break;
            case 'allowed':
                $status['allowed'][] = $value;
                break;
            case 'apply_state':
            case 'apply_message':
            case 'apply_time':
                $status['apply'][substr($key, strlen('apply_'))] = $value;
                break;
        }
    }
    return $status;
}

/** Transmission's own salted SHA-1 form, so the password itself is never stored. */
function transmission_password_hash(string $password): string
{
    // The salt alphabet and length Transmission uses (libtransmission/crypto-utils.cc).
    $alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ./';
    $salt = '';
    for ($i = 0; $i < 8; $i++) {
        $salt .= $alphabet[random_int(0, 63)];
    }
    return '{' . sha1($password . $salt) . $salt;
}

function transmission_save(array $request): void
{
    $errors = [];

    $username = is_string($request['username'] ?? null) ? trim($request['username']) : '';
    if (!preg_match('/^[A-Za-z0-9._@-]{1,64}$/', $username)) {
        $errors['username'] = 'Use 1 to 64 letters, digits, dots, dashes, underscores or @.';
    }

    $password = $request['password'] ?? '';
    if (!is_string($password)) {
        $password = '';
        $errors['password'] = 'The password must be text.';
    } elseif ($password !== '') {
        $length = mb_strlen($password, 'UTF-8');
        if ($length < TR_MIN_PASSWORD || $length > TR_MAX_PASSWORD) {
            $errors['password'] = 'Use ' . TR_MIN_PASSWORD . ' to ' . TR_MAX_PASSWORD . ' characters, or leave it empty to keep the current password.';
        }
    }

    $port = $request['port'] ?? '';
    $port = is_string($port) || is_int($port) ? (string) $port : '';
    if (!preg_match('/^[1-9][0-9]{3,4}$/', $port) || (int) $port > 65535) {
        $errors['port'] = 'Use a number from 1024 to 65535.';
    }

    $patterns = [];
    $allowed = $request['allowed'] ?? null;
    if (!is_array($allowed)) {
        $allowed = [];
    }
    foreach ($allowed as $pattern) {
        $pattern = is_string($pattern) ? trim($pattern) : '';
        // Four dot-separated parts of digits, * ? and [ranges]: what
        // Transmission matches. ctl.sh checks the characters again.
        if (!preg_match('/^[0-9*?\[\]-]{1,15}(\.[0-9*?\[\]-]{1,15}){3}$/', $pattern)) {
            $errors['allowed'] = "\"$pattern\" isn't an address pattern. Use forms such as 192.168.1.* or 10.*.*.*; CIDR such as /24 doesn't work here.";
            break;
        }
        $patterns[] = $pattern;
    }
    if (!isset($errors['allowed'])) {
        if ($patterns === []) {
            $errors['allowed'] = 'List at least one pattern; the defaults allow private home networks and Tailscale.';
        } elseif (count($patterns) > TR_MAX_PATTERNS) {
            $errors['allowed'] = 'Use at most ' . TR_MAX_PATTERNS . ' patterns.';
        }
    }

    if ($errors !== []) {
        api_fail(422, 'Some values need fixing.', $errors);
    }

    $input = ['username' => $username, 'port' => $port, 'allowed' => array_values(array_unique($patterns))];
    if ($password !== '') {
        $input['password_hash'] = transmission_password_hash($password);
    }
    [$code, $output] = api_run_ctl('web-apply', api_input($input));
    if ($code !== 0) {
        api_fail(409, api_output_value($output, 'error') ?? "The NAS didn't accept the change.");
    }
    api_reply(['ok' => true]);
}
