// The tenant this app is built for. tools/tenant.mjs replaces this file in
// each tenant's build with the checked config; in the repository it is the
// default tenant, so the app type-checks and its tests run.
export { default as TENANT } from './tenants/default';
