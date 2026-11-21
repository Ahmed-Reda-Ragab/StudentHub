# CloudWatch Logs Insights + Athena queries

The container logs JSON on stderr (`LOG_CHANNEL=stderr`,
`LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter`, CONVENTIONS §2). One line looks like:

```json
{"message":"SQLSTATE[HY000] [2002] Connection refused","context":{"exception":{"class":"Illuminate\\Database\\QueryException","message":"…","code":2002,"file":"/var/www/html/vendor/…:825"}},"level":500,"level_name":"CRITICAL","channel":"production","datetime":"2026-11-21T10:15:03.123456+02:00","extra":{}}
```

Logs Insights discovers JSON fields automatically: `message`, `level_name`, `channel`,
`datetime`, `context.exception.class`… Lines that are not JSON (nginx access log, PHP-FPM
notices in the same container) only have `@message`.

Log groups: ECS → the task definition's `awslogs-group` (stack 50 output `log_group`);
EC2 → whatever `deploy/ec2/compose.awslogs.yml` sets. Pick the group and the time range in the console.

> What is **not** in the logs: Laravel does not report `HttpException`s (404, 419 CSRF,
> the injected `SRE_FAULT_ERROR_RATE` 500s) or validation errors. Count those from the ALB
> (`HTTPCode_Target_5XX_Count`) or Prometheus, not from logs.

## Laravel application logs

**Errors per 5 minutes, by level**

```
fields @timestamp, level_name
| filter level_name in ["ERROR", "CRITICAL", "ALERT", "EMERGENCY"]
| stats count(*) as errors by bin(5m), level_name
| sort bin(5m) desc
```

**Top error messages (what is actually breaking)**

```
fields @timestamp, level_name, message
| filter level_name in ["ERROR", "CRITICAL", "ALERT", "EMERGENCY"]
| stats count(*) as hits, latest(@timestamp) as last_seen by message
| sort hits desc
| limit 20
```

**Exceptions by class (JsonFormatter normalises the exception into `context.exception`)**

```
fields @timestamp, context.exception.class as exception, context.exception.message as detail, context.exception.file as where
| filter ispresent(exception)
| stats count(*) as hits, latest(detail) as example, latest(where) as at by exception
| sort hits desc
```

**Database trouble during an incident (RDS failover, max connections, credentials)**

```
fields @timestamp, @logStream, message
| filter message like /SQLSTATE|Connection refused|Too many connections|Deadlock|server has gone away/
| stats count(*) as hits by bin(1m), @logStream
| sort bin(1m) desc
```

**Which task / instance is the noisy one** (`@logStream` contains the ECS task id or the container name)

```
fields @logStream, level_name
| filter level_name = "ERROR"
| stats count(*) as errors by @logStream
| sort errors desc
```

**Log volume by level (cost and noise check before/after a release)**

```
stats count(*) as lines by level_name, bin(1h)
```

**Everything around a timestamp (incident timeline)**

```
fields @timestamp, @logStream, level_name, message, @message
| filter @timestamp >= 1763712000000 and @timestamp <= 1763712900000
| sort @timestamp asc
| limit 500
```

## nginx access log lines (same container, plain text)

The image's nginx writes one access line per request; parse it with a regex. Adjust the
pattern if the log format differs (`parse` returns nothing when it does not match):

```
fields @timestamp, @message
| filter @message like /HTTP\/[0-9.]+"/
| parse @message /"(?<method>[A-Z]+) (?<path>[^ ?"]+)[^"]* HTTP\/[0-9.]+" (?<status>\d{3})/
| filter ispresent(status)
| stats count(*) as requests by bin(5m), status
| sort bin(5m) desc
```

## ALB access logs — Athena, not Logs Insights

ALB access logs are written to **S3**, never to CloudWatch Logs, so you query them with
Athena. Enable them on the ALB (attributes `access_logs.s3.enabled=true`,
`access_logs.s3.bucket=<BUCKET>`), then create the table once. The DDL below is the AWS
documented one with partition projection — if Athena reports parsing errors, copy the
current regex from <https://docs.aws.amazon.com/athena/latest/ug/create-alb-access-logs-table-partition-projection.html>
(AWS appends new fields over time).

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS alb_access_logs (
  type string, time string, elb string, client_ip string, client_port int,
  target_ip string, target_port int, request_processing_time double,
  target_processing_time double, response_processing_time double,
  elb_status_code int, target_status_code string, received_bytes bigint, sent_bytes bigint,
  request_verb string, request_url string, request_proto string, user_agent string,
  ssl_cipher string, ssl_protocol string, target_group_arn string, trace_id string,
  domain_name string, chosen_cert_arn string, matched_rule_priority string,
  request_creation_time string, actions_executed string, redirect_url string,
  lambda_error_reason string, target_port_list string, target_status_code_list string,
  classification string, classification_reason string, conn_trace_id string,
  transformed_host string, transformed_uri string, request_transform_status string, ip_address string
)
PARTITIONED BY (day STRING)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.RegexSerDe'
WITH SERDEPROPERTIES (
  'serialization.format' = '1',
  'input.regex' = '([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) \"([^ ]*) (.*) (- |[^ ]*)\" \"([^\"]*)\" ([A-Z0-9-_]+) ([A-Za-z0-9.-]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" ([-.0-9]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^ ]*)\" \"([^\\s]+?)\" \"([^\\s]+)\" \"([^ ]*)\" \"([^ ]*)\" ?([^ ]*)?(?: \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\")?(?: ([^ ]*))? ?( .*)?'
)
LOCATION 's3://<BUCKET>/AWSLogs/<ACCOUNT_ID>/elasticloadbalancing/<REGION>/'
TBLPROPERTIES (
  'projection.enabled' = 'true',
  'projection.day.type' = 'date',
  'projection.day.range' = '2026/01/01,NOW',
  'projection.day.format' = 'yyyy/MM/dd',
  'projection.day.interval' = '1',
  'projection.day.interval.unit' = 'DAYS',
  'storage.location.template' = 's3://<BUCKET>/AWSLogs/<ACCOUNT_ID>/elasticloadbalancing/<REGION>/${day}'
);
```

Always filter on `day` (partition) — it is what keeps Athena cheap.

**Availability per hour (the SLI as users saw it, including ALB-generated 502/503/504)**

```sql
SELECT date_trunc('hour', from_iso8601_timestamp(time)) AS hour,
       count(*) AS requests,
       count_if(elb_status_code >= 500) AS errors_5xx,
       round(100.0 * (1 - count_if(elb_status_code >= 500) / cast(count(*) AS double)), 3) AS availability_pct
FROM alb_access_logs
WHERE day BETWEEN '2026/11/20' AND '2026/11/21'
  AND request_url NOT LIKE '%/sre-lab/%' AND request_url NOT LIKE '%/up' AND request_url NOT LIKE '%/ready'
GROUP BY 1 ORDER BY 1;
```

**Latency percentiles and the latency SLI (share under 300ms)**

```sql
SELECT approx_percentile(target_processing_time, 0.50) AS p50,
       approx_percentile(target_processing_time, 0.95) AS p95,
       approx_percentile(target_processing_time, 0.99) AS p99,
       round(100.0 * count_if(target_processing_time <= 0.3) / cast(count(*) AS double), 2) AS pct_under_300ms
FROM alb_access_logs
WHERE day = '2026/11/21' AND target_processing_time >= 0;   -- -1 = the target never answered
```

**Who produced the 5xx: target (app) or ALB (no healthy target / timeout)?**

```sql
SELECT elb_status_code, target_status_code, target_ip, count(*) AS hits
FROM alb_access_logs
WHERE day = '2026/11/21' AND elb_status_code >= 500
GROUP BY 1, 2, 3 ORDER BY hits DESC LIMIT 20;
```

`target_status_code = '-'` with `elb_status_code = 502/504` means the ALB could not get an
answer (container killed mid-request, idle timeout, deregistration without draining).

**Slowest endpoints (ids collapsed so /students/123 and /students/456 group together)**

```sql
SELECT request_verb,
       regexp_replace(url_extract_path(request_url), '/[0-9]+', '/{id}') AS path,
       count(*) AS hits,
       approx_percentile(target_processing_time, 0.95) AS p95
FROM alb_access_logs
WHERE day = '2026/11/21'
GROUP BY 1, 2 HAVING count(*) > 50
ORDER BY p95 DESC LIMIT 20;
```

**Traffic split per target group during blue/green or canary (weighted target groups)**

```sql
SELECT date_trunc('minute', from_iso8601_timestamp(time)) AS minute,
       regexp_extract(target_group_arn, 'targetgroup/([^/]+)/', 1) AS target_group,
       count(*) AS requests
FROM alb_access_logs
WHERE day = '2026/11/21'
GROUP BY 1, 2 ORDER BY 1, 2;
```
