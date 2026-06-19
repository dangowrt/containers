// monitoring stack — influxdb + grafana
//
// Returns a compose(stack) function declaring the instances on the stack's
// private backhaul. The engine (uxc-stack) qualifies names globally
// (monitoring.influxdb, …); within the stack the short names resolve over the
// backhaul. All wiring lives here, in the template — the feed stays generic.
//
// InfluxDB stores the metrics and pulls them itself: its native scraper polls
// any prometheus-format /metrics endpoint into a bucket (InfluxDB 2.x has no
// prometheus remote-write endpoint, so collection is pull, not push). Grafana
// reads InfluxDB back. Scrape targets are deliberately NOT provisioned here:
// which endpoints to poll is local-admin policy, added at runtime with
//   influx (POST /api/v2/scrapers)  ->  the 'metrics' bucket
// influxdb gets lan egress so the admin can point a scraper at a LAN host.

'use strict';

return function (stack) {
	// the admin API token influxdb mints at first-run setup; grafana reads
	// InfluxDB with it, and the admin's scrapers authenticate with it too.
	let token = stack.generate('influx-token');
	// influxdb's initial setup also needs an admin user + password
	let adminpw = stack.generate('influx-admin-password');

	stack.instance('influxdb', {
		image: 'influxdb',
		// egress=lan: reach scrape targets on LAN hosts. host=tcp/9101: reach the
		// router itself on the prometheus-node-exporter-ucode default port, so
		// scraping the router needs no manual firewall rule. No inbound. The admin
		// still installs the exporter and creates the scraper (the data source);
		// add more host=<proto>/<port> for exporters on other router ports.
		access: 'routed egress=lan host=tcp/9101',
		volumes: [ 'data:/var/lib/influxdb2:64m' ],
		env: {
			DOCKER_INFLUXDB_INIT_MODE: 'setup',
			DOCKER_INFLUXDB_INIT_USERNAME: 'admin',
			DOCKER_INFLUXDB_INIT_PASSWORD: adminpw,
			DOCKER_INFLUXDB_INIT_ORG: 'monitoring',
			DOCKER_INFLUXDB_INIT_BUCKET: 'metrics',
			DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: token,
			// the image defaults this to /etc/influxdb2 (read-only rootfs);
			// keep influx setup's config write on the writable data volume
			INFLUX_CONFIGS_PATH: '/var/lib/influxdb2/configs',
		},
	});

	stack.instance('grafana', {
		image: 'grafana',
		access: 'routed ingress=lan:tcp/3000',   // UI on LAN
		volumes: [ 'data:/var/lib/grafana:16m' ],
		env: { INFLUX_TOKEN: token },
		// provision an InfluxDB (Flux) datasource; grafana expands $INFLUX_TOKEN
		// from the env, so the token is never written into a file.
		provision: {
			'/etc/grafana/provisioning/datasources/influxdb.yaml':
				"apiVersion: 1\n" +
				"datasources:\n" +
				"  - name: InfluxDB\n" +
				"    type: influxdb\n" +
				"    access: proxy\n" +
				"    url: http://influxdb:8086\n" +
				"    jsonData:\n" +
				"      version: Flux\n" +
				"      organization: monitoring\n" +
				"      defaultBucket: metrics\n" +
				"    secureJsonData:\n" +
				"      token: $INFLUX_TOKEN\n",
		},
	});
};
