# PioneerPath Data Privacy Inventory

PioneerPath processes personal data covered by the Philippine Data Privacy Act
of 2012, Republic Act No. 10173. This document identifies the personal data
handled by the current Laravel backend and Flutter applications and the controls
implemented to limit exposure.

## Personal Data Fields

### Staff And User Accounts

- `users.name`
- `users.email`
- `users.phone`
- `users.last_login_at`
- `login_attempt_logs.email`
- `login_attempt_logs.ip_address`
- `login_attempt_logs.attempted_at`

### Drivers

- `manual_drivers.name`
- `manual_drivers.license`
- `manual_drivers.phone`
- `manual_drivers.email`
- `manual_drivers.meta.address`
- `manual_drivers.meta.emergencyContact`
- driver assignments to vehicle plate/device identifiers
- driver names contained in trip snapshots, dispatch cards, analytics, and
  write-back payloads

### Clients And Customer Contacts

- `fleet_clients.company_name` when tied to a natural person or sole proprietor
- `fleet_clients.contact_person_name`
- `fleet_clients.contact_number`
- `fleet_clients.email`
- `fleet_clients.billing_address`
- `fleet_clients.delivery_address`
- client/contact fields in `client_vehicle_assignments`
- recipient names and notes in proof-of-delivery records

### Location And Operational Records

- `gps_logs.latitude`
- `gps_logs.longitude`
- `gps_logs.recorded_at`
- `gps_logs.device_geotab_id`
- `gps_logs.trip_id`
- route history returned by trip maps, client tracking, and vehicle trails
- GeoTab feed row payloads that include device, driver, route, trip, zone, or
  diagnostic records
- zone/geofence visit timestamps tied to vehicles, drivers, or client sites

### Billing And Delivery Documents

- `billing_invoice_references.po_number`
- `billing_invoice_references.dr_number`
- `billing_invoice_references.erp_reference`
- client names and addresses shown in delivery trip billing and statement of
  accounts views
- proof-of-delivery signature images and uploaded proof files

## Access Controls

- Protected API routes require authenticated JWT access tokens.
- Role checks are enforced by backend middleware before controller execution.
- Driver location history is restricted to Super Administrator, System
  Administrator, Fleet Manager, and Dispatcher roles.
- Driver accounts can only access their own trip tracker or route history.
- Accounting Staff and Drivers are denied vehicle trail and trip map location
  history that is not required for their work.
- Driver-facing trip responses mask full client contact data such as phone
  numbers and addresses.
- Proof-of-delivery files are stored on the private Laravel disk and served
  through authenticated controller actions.

## Logging Rules

Application logs must not contain plain-text personal data. The production error
reporter masks request keys that contain personal data indicators such as
`name`, `email`, `phone`, `contact`, `license`, `address`, `driver`, `client`,
`customer`, `recipient`, `latitude`, and `longitude`. Authentication logs mask
email addresses before writing them.

Never log:

- passwords or temporary passwords;
- JWT access or refresh tokens;
- GeoTab credentials;
- Google Maps or VAPID keys;
- driver license numbers;
- client contact numbers;
- raw GPS coordinate streams tied to a person.

## Retention Controls

Retention is configurable from System Settings:

- GPS log retention: default 90 days, minimum 30 days.
- Raw GeoTab feed row retention: default 30 days.
- Notification history retention: default 90 days, minimum 30 days.
- Audit log retention: default 365 days, minimum 365 days.

The scheduled `geotab:feed-prune` command reads these settings and prunes local
GPS logs, raw GeoTab feed rows, route stop snapshots, and notification history
accordingly. It also prunes JSON audit trail entries from system settings,
fleet clients, and GeoTab write-back jobs when those entries are older than the
configured audit-retention window. Audit logs are retained for at least one
year.

## Driver Anonymization

When a driver account is deactivated, a Super Administrator may anonymize the
driver's profile data on request. The anonymization action removes:

- license number;
- phone number;
- email address;
- home address;
- emergency contact.

Trip history, vehicle assignments, and operational reporting records are
preserved for legitimate business reporting.

## Operational Notes

- Do not export production data to local machines unless approved by the data
  owner.
- Use production database backups only through the documented secure backup and
  restore process.
- When sharing screenshots, mask client contact details, driver licenses, phone
  numbers, addresses, and precise location history unless the recipient has a
  business need.
