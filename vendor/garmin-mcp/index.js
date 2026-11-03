#!/usr/bin/env node

// src/index.ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// src/garmin/client.ts
import axios2 from "axios";

// src/garmin/constants.ts
var HOSTS = {
  SSO: "https://sso.garmin.com",
  CONNECT: "https://connect.garmin.com",
  CONNECT_API: "https://connectapi.garmin.com"
};
var URLS = {
  SSO_EMBED: `${HOSTS.SSO}/sso/embed`,
  SSO_SIGNIN: `${HOSTS.SSO}/sso/signin`,
  SSO_VERIFY_MFA: `${HOSTS.SSO}/sso/verifyMFA/loginEnterMfaCode`,
  GC_MODERN: `${HOSTS.CONNECT}/modern`,
  SSO_ORIGIN: HOSTS.SSO,
  OAUTH_PREAUTH: `${HOSTS.CONNECT_API}/oauth-service/oauth/preauthorized`,
  OAUTH_EXCHANGE: `${HOSTS.CONNECT_API}/oauth-service/oauth/exchange/user/2.0`
};
var OAUTH_CONSUMER = {
  key: "fc3e99d2-118c-44b8-8ae3-03370dde24c0",
  secret: "E08WAR897WEy2knn7aFBrvegVAf0AFdWBBF"
};
var UA_MOBILE = "com.garmin.android.apps.connectmobile";
var REQUEST_TIMEOUT_MS = 2e4;

// src/garmin/auth.ts
import crypto from "crypto";
import axios from "axios";
import { CookieJar } from "tough-cookie";
import { wrapper } from "axios-cookiejar-support";
import OAuth from "oauth-1.0a";
function oauthClient() {
  return new OAuth({
    consumer: { key: OAUTH_CONSUMER.key, secret: OAUTH_CONSUMER.secret },
    signature_method: "HMAC-SHA1",
    hash_function(base, key) {
      return crypto.createHmac("sha1", key).update(base).digest("base64");
    }
  });
}
async function exchange(oauth1) {
  const oauth = oauthClient();
  const token = { key: oauth1.oauth_token, secret: oauth1.oauth_token_secret };
  const url = URLS.OAUTH_EXCHANGE;
  const authHeader = oauth.toHeader(oauth.authorize({ url, method: "POST" }, token));
  const res = await axios.post(url, "", {
    timeout: REQUEST_TIMEOUT_MS,
    headers: {
      ...authHeader,
      "User-Agent": UA_MOBILE,
      "Content-Type": "application/x-www-form-urlencoded"
    }
  });
  const data = res.data;
  if (!data?.access_token) {
    throw new Error("Login failed: OAuth2 exchange did not return an access token.");
  }
  data.expires_at = Math.floor(Date.now() / 1e3) + (data.expires_in ?? 0);
  return data;
}

// src/garmin/tokenStore.ts
import { homedir } from "os";
import { join } from "path";
import { mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync } from "fs";
function tokenDir() {
  return process.env.GARMIN_MCP_TOKEN_DIR || join(homedir(), ".garmin-mcp");
}
function tokenPath() {
  return join(tokenDir(), "tokens.json");
}
function loadTokens() {
  const p = tokenPath();
  if (!existsSync(p)) return null;
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
}
function saveTokens(tokens) {
  const dir = tokenDir();
  mkdirSync(dir, { recursive: true, mode: 448 });
  const p = tokenPath();
  writeFileSync(p, JSON.stringify(tokens, null, 2), { mode: 384 });
  chmodSync(p, 384);
}

// src/garmin/endpoints.ts
var API = HOSTS.CONNECT_API;
var ep = {
  // --- Profile / account ---
  socialProfile: () => `${API}/userprofile-service/socialProfile`,
  userSettings: () => `${API}/userprofile-service/userprofile/user-settings`,
  // --- Activities ---
  activities: (start, limit, activityType) => `${API}/activitylist-service/activities/search/activities?start=${start}&limit=${limit}` + (activityType ? `&activityType=${encodeURIComponent(activityType)}` : ""),
  activitiesByDate: (startDate, endDate, limit, activityType) => `${API}/activitylist-service/activities/search/activities?startDate=${startDate}&endDate=${endDate}&start=0&limit=${limit}` + (activityType ? `&activityType=${encodeURIComponent(activityType)}` : ""),
  activitiesCount: () => `${API}/activitylist-service/activities/count`,
  activity: (id) => `${API}/activity-service/activity/${id}`,
  activityDetails: (id) => `${API}/activity-service/activity/${id}/details?maxChartSize=2000&maxPolylineSize=4000`,
  activityTypes: () => `${API}/activity-service/activity/activityTypes`,
  activityWeather: (id) => `${API}/activity-service/activity/${id}/weather`,
  activitySplits: (id) => `${API}/activity-service/activity/${id}/splits`,
  activityTypedSplits: (id) => `${API}/activity-service/activity/${id}/typedsplits`,
  activitySplitSummaries: (id) => `${API}/activity-service/activity/${id}/split_summaries`,
  activityHrZones: (id) => `${API}/activity-service/activity/${id}/hrTimeInZones`,
  activityPowerZones: (id) => `${API}/activity-service/activity/${id}/powerTimeInZones`,
  activityExerciseSets: (id) => `${API}/activity-service/activity/${id}/exerciseSets`,
  activityGear: (id) => `${API}/gear-service/gear/filterGear?activityId=${id}`,
  progressSummary: (startDate, endDate, metric) => `${API}/fitnessstats-service/activity?startDate=${startDate}&endDate=${endDate}&aggregation=lifetime&groupByParentActivityType=true&metric=${metric}`,
  // --- Daily wellness ---
  dailySummary: (displayName, date) => `${API}/usersummary-service/usersummary/daily/${displayName}?calendarDate=${date}`,
  steps: (date) => `${API}/usersummary-service/stats/steps/daily/${date}/${date}`,
  stepsChart: (displayName, date) => `${API}/wellness-service/wellness/dailySummaryChart/${displayName}?date=${date}`,
  heartRate: (displayName, date) => `${API}/wellness-service/wellness/dailyHeartRate/${displayName}?date=${date}`,
  sleep: (displayName, date) => `${API}/wellness-service/wellness/dailySleepData/${displayName}?date=${date}&nonSleepBufferMinutes=60`,
  sleepRaw: (displayName, date) => `${API}/wellness-service/wellness/dailySleepData/${displayName}?date=${date}`,
  bodyBattery: (startDate, endDate) => `${API}/wellness-service/wellness/bodyBattery/reports/daily?startDate=${startDate}&endDate=${endDate}`,
  bodyBatteryEvents: (date) => `${API}/wellness-service/wellness/bodyBattery/events/${date}`,
  stress: (date) => `${API}/wellness-service/wellness/dailyStress/${date}`,
  respiration: (date) => `${API}/wellness-service/wellness/daily/respiration/${date}`,
  spo2: (date) => `${API}/wellness-service/wellness/daily/spo2/${date}`,
  intensityMinutes: (date) => `${API}/wellness-service/wellness/daily/im/${date}`,
  floors: (date) => `${API}/wellness-service/wellness/floorsChartData/daily/${date}`,
  dailyEvents: (date) => `${API}/wellness-service/wellness/dailyEvents?calendarDate=${date}`,
  hrv: (date) => `${API}/hrv-service/hrv/${date}`,
  restingHeartRate: (displayName, date) => `${API}/userstats-service/wellness/daily/${displayName}?fromDate=${date}&untilDate=${date}&metricId=60`,
  hydration: (date) => `${API}/usersummary-service/usersummary/hydration/allData/${date}`,
  // --- Weekly / multi-day stats ---
  dailyStepsRange: (startDate, endDate) => `${API}/usersummary-service/stats/steps/daily/${startDate}/${endDate}`,
  weeklySteps: (endDate, weeks) => `${API}/usersummary-service/stats/steps/weekly/${endDate}/${weeks}`,
  weeklyStress: (endDate, weeks) => `${API}/usersummary-service/stats/stress/weekly/${endDate}/${weeks}`,
  weeklyIntensityMinutes: (startDate, endDate) => `${API}/usersummary-service/stats/im/weekly/${startDate}/${endDate}`,
  // --- Weight / body composition / blood pressure ---
  weightRange: (start, end) => `${API}/weight-service/weight/range/${start}/${end}?includeAll=true`,
  bodyComposition: (startDate, endDate) => `${API}/weight-service/weight/dateRange?startDate=${startDate}&endDate=${endDate}`,
  dailyWeighIns: (date) => `${API}/weight-service/weight/dayview/${date}?includeAll=true`,
  bloodPressure: (startDate, endDate) => `${API}/bloodpressure-service/bloodpressure/range/${startDate}/${endDate}`,
  // --- Training / performance metrics ---
  maxMetrics: (start, end) => `${API}/metrics-service/metrics/maxmet/daily/${start}/${end}`,
  trainingReadiness: (date) => `${API}/metrics-service/metrics/trainingreadiness/${date}`,
  trainingStatus: (date) => `${API}/metrics-service/metrics/trainingstatus/aggregated/${date}`,
  enduranceScore: (date) => `${API}/metrics-service/metrics/endurancescore?calendarDate=${date}`,
  hillScore: (date) => `${API}/metrics-service/metrics/hillscore?calendarDate=${date}`,
  racePredictions: (displayName) => `${API}/metrics-service/metrics/racepredictions/latest/${displayName}`,
  fitnessAge: (date) => `${API}/fitnessage-service/fitnessage/${date}`,
  lactateThreshold: () => `${API}/biometric-service/biometric/latestLactateThreshold`,
  cyclingFtp: () => `${API}/biometric-service/biometric/latestFunctionalThresholdPower/CYCLING`,
  personalRecords: (displayName) => `${API}/personalrecord-service/personalrecord/prs/${displayName}`,
  // --- Workouts & training plans ---
  workouts: (start, limit) => `${API}/workout-service/workouts?start=${start}&limit=${limit}&myWorkoutsOnly=true`,
  workout: (id) => `${API}/workout-service/workout/${id}`,
  scheduledWorkout: (id) => `${API}/workout-service/schedule/${id}`,
  trainingPlans: (start, limit) => `${API}/trainingplan-service/trainingplan/plans?start=${start}&limit=${limit}`,
  trainingPlan: (id) => `${API}/trainingplan-service/trainingplan/${id}`,
  adaptiveTrainingPlan: (id) => `${API}/trainingplan-service/trainingplan/adaptive/${id}`,
  // --- Gear ---
  gear: (profileId) => `${API}/gear-service/gear/filterGear?userProfilePk=${profileId}`,
  gearStats: (gearUuid) => `${API}/gear-service/gear/stats/${gearUuid}`,
  gearActivities: (gearUuid, start, limit) => `${API}/activitylist-service/activities/${gearUuid}/gear?start=${start}&limit=${limit}`,
  gearDefaults: (profileId) => `${API}/gear-service/gear/user/${profileId}/activityTypes`,
  // --- Devices ---
  devices: () => `${API}/device-service/deviceregistration/devices`,
  deviceSettings: (deviceId) => `${API}/device-service/deviceservice/device-info/settings/${deviceId}`,
  deviceLastUsed: () => `${API}/device-service/deviceservice/mylastused`,
  primaryTrainingDevice: () => `${API}/web-gateway/device-info/primary-training-device`,
  deviceSolar: (deviceId, startDate, endDate) => `${API}/web-gateway/solar/${deviceId}?startDate=${startDate}&endDate=${endDate}` + (startDate === endDate ? "&singleDayView=true" : ""),
  // --- Goals, badges & challenges ---
  goals: (status, start) => `${API}/goal-service/goal/goals?status=${status}&start=${start}&limit=100&sortOrder=asc`,
  earnedBadges: () => `${API}/badge-service/badge/earned`,
  availableBadges: () => `${API}/badge-service/badge/available`,
  adhocChallenges: () => `${API}/adhocchallenge-service/adHocChallenge/historical`,
  badgeChallenges: () => `${API}/badgechallenge-service/badgeChallenge/completed`,
  availableBadgeChallenges: () => `${API}/badgechallenge-service/badgeChallenge/available`,
  nonCompletedBadgeChallenges: () => `${API}/badgechallenge-service/badgeChallenge/non-completed`,
  inProgressVirtualChallenges: () => `${API}/badgechallenge-service/virtualChallenge/inProgress`,
  // --- Women's health ---
  menstrualCalendar: (startDate, endDate) => `${API}/periodichealth-service/menstrualcycle/calendar?startDate=${startDate}&endDate=${endDate}`,
  menstrualDayView: (date) => `${API}/periodichealth-service/menstrualcycle/dayview/${date}`,
  pregnancySummary: () => `${API}/periodichealth-service/menstrualcycle/pregnancysnapshot`,
  lifestyleLogging: (date) => `${API}/lifestylelogging-service/dailyLog/${date}`,
  // --- Calendar ---
  calendar: (year, month) => (
    // Garmin months are 0-indexed in this endpoint.
    `${API}/calendar-service/year/${year}/month/${month - 1}`
  )
};

// src/garmin/client.ts
var REFRESH_SKEW_SECONDS = 60;
var GarminClient = class _GarminClient {
  tokens;
  http;
  refreshing = null;
  displayName = null;
  profileId = null;
  constructor(tokens) {
    this.tokens = tokens;
    this.http = axios2.create({
      baseURL: HOSTS.CONNECT_API,
      timeout: REQUEST_TIMEOUT_MS,
      headers: { "User-Agent": UA_MOBILE, "Accept": "application/json" }
    });
  }
  // Construct from cached tokens. Throws a clear message if setup hasn't run.
  static fromCache() {
    const tokens = loadTokens();
    if (!tokens) {
      throw new Error(
        "No cached Garmin tokens found. Run the one-time `setup` command first (see README)."
      );
    }
    return new _GarminClient(tokens);
  }
  async ensureFreshToken() {
    const now = Math.floor(Date.now() / 1e3);
    if (this.tokens.oauth2.expires_at - REFRESH_SKEW_SECONDS > now) return;
    if (!this.refreshing) {
      this.refreshing = (async () => {
        const oauth2 = await exchange(this.tokens.oauth1);
        this.tokens = { ...this.tokens, oauth2 };
        saveTokens(this.tokens);
      })().finally(() => {
        this.refreshing = null;
      });
    }
    await this.refreshing;
  }
  // Authenticated GET returning parsed JSON. Retries once on 401 after refresh.
  async get(url) {
    await this.ensureFreshToken();
    try {
      return await this.rawGet(url);
    } catch (err) {
      if (axios2.isAxiosError(err) && err.response?.status === 401) {
        await this.forceRefresh();
        return await this.rawGet(url);
      }
      throw new Error(describeError(url, err));
    }
  }
  async rawGet(url) {
    const res = await this.http.get(url, {
      headers: { Authorization: `Bearer ${this.tokens.oauth2.access_token}` }
    });
    return res.data;
  }
  async forceRefresh() {
    const oauth2 = await exchange(this.tokens.oauth1);
    this.tokens = { ...this.tokens, oauth2 };
    saveTokens(this.tokens);
  }
  async getDisplayName() {
    await this.loadProfile();
    return this.displayName;
  }
  async getProfileId() {
    await this.loadProfile();
    return this.profileId;
  }
  async loadProfile() {
    if (this.displayName && this.profileId) return;
    const profile = await this.get(
      ep.socialProfile()
    );
    if (!profile.displayName || !profile.profileId) {
      throw new Error("Could not resolve account profile (displayName / profileId).");
    }
    this.displayName = profile.displayName;
    this.profileId = profile.profileId;
  }
};
function describeError(url, err) {
  if (axios2.isAxiosError(err)) {
    const status = err.response?.status;
    const host = safeHost(url);
    if (status === 401 || status === 403) {
      return `Garmin rejected the request (HTTP ${status}). Tokens may be invalid \u2014 re-run \`setup\`.`;
    }
    if (status) return `Garmin API error HTTP ${status} for ${host}.`;
    return `Network error contacting ${host}: ${err.message}`;
  }
  return err instanceof Error ? err.message : String(err);
}
function safeHost(url) {
  try {
    return new URL(url, HOSTS.CONNECT_API).host;
  } catch {
    return "garmin";
  }
}

// src/tools/index.ts
import { z } from "zod";
function ymd(d) {
  const tz = d.getTimezoneOffset() * 6e4;
  return new Date(d.getTime() - tz).toISOString().slice(0, 10);
}
function today() {
  return ymd(/* @__PURE__ */ new Date());
}
function daysAgo(n) {
  const d = /* @__PURE__ */ new Date();
  d.setDate(d.getDate() - n);
  return ymd(d);
}
var dateField = {
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Date must be YYYY-MM-DD").optional().describe("Calendar date YYYY-MM-DD. Defaults to today.")
};
var startEndFields = {
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Date must be YYYY-MM-DD").describe("Range start date YYYY-MM-DD."),
  endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Date must be YYYY-MM-DD").describe("Range end date YYYY-MM-DD.")
};
var activityIdField = {
  activityId: z.union([z.string(), z.number()]).describe("The Garmin activity ID.")
};
function resolveDate(args) {
  return args.date || today();
}
var aid = (a) => a.activityId;
var tools = [
  // ===================================================================
  // Activities
  // ===================================================================
  {
    name: "get_last_activity",
    description: "Get the most recent recorded activity (run, ride, swim, etc.) with its summary stats.",
    inputSchema: {},
    handler: async (c) => {
      const list = await c.get(ep.activities(0, 1));
      return Array.isArray(list) ? list[0] ?? null : list;
    }
  },
  {
    name: "get_activities",
    description: "List recent activities, newest first. Supports pagination and optional activity-type filter.",
    inputSchema: {
      start: z.number().int().min(0).optional().describe("Offset for pagination. Default 0."),
      limit: z.number().int().min(1).max(50).optional().describe("How many to return (1-50). Default 10."),
      activityType: z.string().optional().describe("Filter by type key, e.g. 'running', 'cycling', 'lap_swimming'.")
    },
    handler: async (c, a) => c.get(ep.activities(a.start ?? 0, a.limit ?? 10, a.activityType))
  },
  {
    name: "get_activities_by_date",
    description: "List activities within a date range (newest first), optionally filtered by activity type.",
    inputSchema: {
      ...startEndFields,
      activityType: z.string().optional().describe("Filter by type key, e.g. 'running', 'cycling'."),
      limit: z.number().int().min(1).max(100).optional().describe("Max activities to return (1-100). Default 100.")
    },
    handler: async (c, a) => c.get(
      ep.activitiesByDate(
        a.startDate,
        a.endDate,
        a.limit ?? 100,
        a.activityType
      )
    )
  },
  {
    name: "count_activities",
    description: "Get the total number of recorded activities on the account.",
    inputSchema: {},
    handler: async (c) => c.get(ep.activitiesCount())
  },
  {
    name: "get_activity_types",
    description: "List the activity-type keys Garmin recognizes (useful for filtering other queries).",
    inputSchema: {},
    handler: async (c) => c.get(ep.activityTypes())
  },
  {
    name: "get_activity_details",
    description: "Get full details for a single activity by its numeric activity ID (includes metric charts).",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityDetails(aid(a)))
  },
  {
    name: "get_activity_summary",
    description: "Get the top-level summary record for a single activity by ID (without large detail charts).",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activity(aid(a)))
  },
  {
    name: "get_activity_weather",
    description: "Get the weather conditions recorded during an activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityWeather(aid(a)))
  },
  {
    name: "get_activity_splits",
    description: "Get per-split data for an activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activitySplits(aid(a)))
  },
  {
    name: "get_activity_typed_splits",
    description: "Get typed splits (e.g. interval/recovery laps) for an activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityTypedSplits(aid(a)))
  },
  {
    name: "get_activity_split_summaries",
    description: "Get aggregated split summaries for an activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activitySplitSummaries(aid(a)))
  },
  {
    name: "get_activity_hr_zones",
    description: "Get time spent in each heart-rate zone for an activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityHrZones(aid(a)))
  },
  {
    name: "get_activity_power_zones",
    description: "Get time spent in each power zone for an activity (cycling/running power).",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityPowerZones(aid(a)))
  },
  {
    name: "get_activity_exercise_sets",
    description: "Get exercise sets (reps/weights) recorded during a strength activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityExerciseSets(aid(a)))
  },
  {
    name: "get_activity_gear",
    description: "Get the gear (shoes/bike) linked to a specific activity.",
    inputSchema: { ...activityIdField },
    handler: async (c, a) => c.get(ep.activityGear(aid(a)))
  },
  {
    name: "get_progress_summary",
    description: "Get aggregated activity progress stats over a date range for a metric (e.g. distance, duration, elevationGain).",
    inputSchema: {
      ...startEndFields,
      metric: z.string().optional().describe("Metric to aggregate. Default 'distance'.")
    },
    handler: async (c, a) => c.get(ep.progressSummary(a.startDate, a.endDate, a.metric ?? "distance"))
  },
  // ===================================================================
  // Daily wellness
  // ===================================================================
  {
    name: "get_daily_summary",
    description: "Get the daily wellness summary (steps, calories, intensity minutes, resting HR, stress, body battery) for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.dailySummary(await c.getDisplayName(), resolveDate(a)))
  },
  {
    name: "get_steps",
    description: "Get step count totals for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.steps(resolveDate(a)))
  },
  {
    name: "get_steps_chart",
    description: "Get intraday step chart data (per-interval steps) for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.stepsChart(await c.getDisplayName(), resolveDate(a)))
  },
  {
    name: "get_heart_rate",
    description: "Get heart-rate time series and min/max/resting values for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.heartRate(await c.getDisplayName(), resolveDate(a)))
  },
  {
    name: "get_resting_heart_rate",
    description: "Get the resting heart rate for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.restingHeartRate(await c.getDisplayName(), resolveDate(a)))
  },
  {
    name: "get_sleep_data",
    description: "Get sleep data for a date: stages, duration, sleep score, and overnight metrics.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.sleep(await c.getDisplayName(), resolveDate(a)))
  },
  {
    name: "get_sleep_data_raw",
    description: "Get raw sleep data for a date (without the non-sleep buffer adjustment).",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.sleepRaw(await c.getDisplayName(), resolveDate(a)))
  },
  {
    name: "get_body_battery",
    description: "Get Body Battery (energy) readings for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => {
      const d = resolveDate(a);
      return c.get(ep.bodyBattery(d, d));
    }
  },
  {
    name: "get_body_battery_events",
    description: "Get Body Battery events (activities/sleep/stress that changed energy) for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.bodyBatteryEvents(resolveDate(a)))
  },
  {
    name: "get_stress",
    description: "Get all-day stress level data for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.stress(resolveDate(a)))
  },
  {
    name: "get_respiration",
    description: "Get all-day respiration (breaths per minute) data for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.respiration(resolveDate(a)))
  },
  {
    name: "get_spo2",
    description: "Get pulse ox (SpO2 blood oxygen) data for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.spo2(resolveDate(a)))
  },
  {
    name: "get_intensity_minutes",
    description: "Get moderate/vigorous intensity minutes for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.intensityMinutes(resolveDate(a)))
  },
  {
    name: "get_floors",
    description: "Get floors climbed/descended chart data for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.floors(resolveDate(a)))
  },
  {
    name: "get_daily_events",
    description: "Get the day's logged events/timeline for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.dailyEvents(resolveDate(a)))
  },
  {
    name: "get_hrv",
    description: "Get Heart Rate Variability (HRV) data for a date, including overnight average and status.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.hrv(resolveDate(a)))
  },
  {
    name: "get_hydration",
    description: "Get hydration (fluid intake) data for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.hydration(resolveDate(a)))
  },
  {
    name: "get_daily_health_snapshot",
    description: "Get a combined health snapshot for a date (summary, heart rate, stress, body battery, sleep, HRV, respiration, SpO2, steps, floors, intensity minutes) in one call.",
    inputSchema: { ...dateField },
    handler: async (c, a) => {
      const date = resolveDate(a);
      const dn = await c.getDisplayName();
      const safe = async (p) => p.catch(() => null);
      const [summary, heartRate, stress, bodyBattery, sleep, hrv, respiration, spo2, steps, floors, intensityMinutes] = await Promise.all([
        safe(c.get(ep.dailySummary(dn, date))),
        safe(c.get(ep.heartRate(dn, date))),
        safe(c.get(ep.stress(date))),
        safe(c.get(ep.bodyBattery(date, date))),
        safe(c.get(ep.sleep(dn, date))),
        safe(c.get(ep.hrv(date))),
        safe(c.get(ep.respiration(date))),
        safe(c.get(ep.spo2(date))),
        safe(c.get(ep.stepsChart(dn, date))),
        safe(c.get(ep.floors(date))),
        safe(c.get(ep.intensityMinutes(date)))
      ]);
      return { date, summary, heartRate, stress, bodyBattery, sleep, hrv, respiration, spo2, steps, floors, intensityMinutes };
    }
  },
  // ===================================================================
  // Multi-day / weekly stats
  // ===================================================================
  {
    name: "get_daily_steps_range",
    description: "Get daily step totals across a date range.",
    inputSchema: { ...startEndFields },
    handler: async (c, a) => c.get(ep.dailyStepsRange(a.startDate, a.endDate))
  },
  {
    name: "get_weekly_steps",
    description: "Get weekly step totals ending on a date.",
    inputSchema: {
      endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Date must be YYYY-MM-DD").optional().describe("End date YYYY-MM-DD. Defaults to today."),
      weeks: z.number().int().min(1).max(52).optional().describe("How many weeks back (1-52). Default 4.")
    },
    handler: async (c, a) => c.get(ep.weeklySteps(a.endDate || today(), a.weeks ?? 4))
  },
  {
    name: "get_weekly_stress",
    description: "Get weekly average stress ending on a date.",
    inputSchema: {
      endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Date must be YYYY-MM-DD").optional().describe("End date YYYY-MM-DD. Defaults to today."),
      weeks: z.number().int().min(1).max(52).optional().describe("How many weeks back (1-52). Default 4.")
    },
    handler: async (c, a) => c.get(ep.weeklyStress(a.endDate || today(), a.weeks ?? 4))
  },
  {
    name: "get_weekly_intensity_minutes",
    description: "Get weekly intensity minutes across a date range.",
    inputSchema: { ...startEndFields },
    handler: async (c, a) => c.get(ep.weeklyIntensityMinutes(a.startDate, a.endDate))
  },
  // ===================================================================
  // Weight / body composition / blood pressure
  // ===================================================================
  {
    name: "get_latest_weight",
    description: "Get the most recent body weight measurement (searches the last 30 days).",
    inputSchema: {},
    handler: async (c) => c.get(ep.weightRange(daysAgo(30), today()))
  },
  {
    name: "get_daily_weigh_ins",
    description: "Get all weigh-ins recorded on a specific date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.dailyWeighIns(resolveDate(a)))
  },
  {
    name: "get_weigh_ins",
    description: "Get weigh-ins across a date range.",
    inputSchema: { ...startEndFields },
    handler: async (c, a) => c.get(ep.weightRange(a.startDate, a.endDate))
  },
  {
    name: "get_body_composition",
    description: "Get body composition (weight, BMI, body fat, muscle mass, etc.) across a date range.",
    inputSchema: { ...startEndFields },
    handler: async (c, a) => c.get(ep.bodyComposition(a.startDate, a.endDate))
  },
  {
    name: "get_blood_pressure",
    description: "Get blood pressure readings across a date range.",
    inputSchema: { ...startEndFields },
    handler: async (c, a) => c.get(ep.bloodPressure(a.startDate, a.endDate))
  },
  // ===================================================================
  // Training / performance metrics
  // ===================================================================
  {
    name: "get_vo2max",
    description: "Get recent VO2 max / MaxMet estimates (running & cycling). Returns the last 14 days; the latest entry is the current estimate.",
    inputSchema: {},
    handler: async (c) => c.get(ep.maxMetrics(daysAgo(14), today()))
  },
  {
    name: "get_training_readiness",
    description: "Get the Training Readiness score and contributing factors for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.trainingReadiness(resolveDate(a)))
  },
  {
    name: "get_training_status",
    description: "Get aggregated training status for a date (load, status, VO2 max, acute load).",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.trainingStatus(resolveDate(a)))
  },
  {
    name: "get_endurance_score",
    description: "Get the Endurance Score for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.enduranceScore(resolveDate(a)))
  },
  {
    name: "get_hill_score",
    description: "Get the Hill Score (climbing strength) for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.hillScore(resolveDate(a)))
  },
  {
    name: "get_race_predictions",
    description: "Get latest predicted race times (5K, 10K, half, marathon).",
    inputSchema: {},
    handler: async (c) => c.get(ep.racePredictions(await c.getDisplayName()))
  },
  {
    name: "get_fitness_age",
    description: "Get the estimated fitness age for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.fitnessAge(resolveDate(a)))
  },
  {
    name: "get_lactate_threshold",
    description: "Get the latest lactate threshold (heart rate & pace).",
    inputSchema: {},
    handler: async (c) => c.get(ep.lactateThreshold())
  },
  {
    name: "get_cycling_ftp",
    description: "Get the latest cycling Functional Threshold Power (FTP).",
    inputSchema: {},
    handler: async (c) => c.get(ep.cyclingFtp())
  },
  {
    name: "get_personal_records",
    description: "Get your personal records (fastest times, longest runs, etc.).",
    inputSchema: {},
    handler: async (c) => c.get(ep.personalRecords(await c.getDisplayName()))
  },
  // ===================================================================
  // Workouts & training plans
  // ===================================================================
  {
    name: "get_workouts",
    description: "List your saved workouts (paginated via start/limit).",
    inputSchema: {
      start: z.number().int().min(0).optional().describe("Offset for pagination. Default 0."),
      limit: z.number().int().min(1).max(50).optional().describe("How many to return (1-50). Default 10.")
    },
    handler: async (c, a) => c.get(ep.workouts(a.start ?? 0, a.limit ?? 10))
  },
  {
    name: "get_workout_details",
    description: "Get full details for a single saved workout by its ID.",
    inputSchema: {
      workoutId: z.union([z.string(), z.number()]).describe("The Garmin workout ID.")
    },
    handler: async (c, a) => c.get(ep.workout(a.workoutId))
  },
  {
    name: "get_scheduled_workout",
    description: "Get a scheduled workout by its schedule ID.",
    inputSchema: {
      scheduleId: z.union([z.string(), z.number()]).describe("The Garmin workout schedule ID.")
    },
    handler: async (c, a) => c.get(ep.scheduledWorkout(a.scheduleId))
  },
  {
    name: "get_training_plans",
    description: "List your training plans (paginated via start/limit).",
    inputSchema: {
      start: z.number().int().min(0).optional().describe("Offset for pagination. Default 0."),
      limit: z.number().int().min(1).max(50).optional().describe("How many to return (1-50). Default 20.")
    },
    handler: async (c, a) => c.get(ep.trainingPlans(a.start ?? 0, a.limit ?? 20))
  },
  {
    name: "get_training_plan_details",
    description: "Get full details for a single training plan by its ID.",
    inputSchema: {
      planId: z.union([z.string(), z.number()]).describe("The Garmin training plan ID.")
    },
    handler: async (c, a) => c.get(ep.trainingPlan(a.planId))
  },
  {
    name: "get_adaptive_training_plan",
    description: "Get details for an adaptive (Garmin Coach) training plan by its ID.",
    inputSchema: {
      planId: z.union([z.string(), z.number()]).describe("The Garmin adaptive training plan ID.")
    },
    handler: async (c, a) => c.get(ep.adaptiveTrainingPlan(a.planId))
  },
  // ===================================================================
  // Gear
  // ===================================================================
  {
    name: "get_gear",
    description: "List your registered gear (shoes, bikes) and their usage.",
    inputSchema: {},
    handler: async (c) => c.get(ep.gear(await c.getProfileId()))
  },
  {
    name: "get_gear_stats",
    description: "Get usage stats (total distance, activity count) for one piece of gear.",
    inputSchema: {
      gearUuid: z.string().describe("The gear UUID (from get_gear).")
    },
    handler: async (c, a) => c.get(ep.gearStats(a.gearUuid))
  },
  {
    name: "get_gear_activities",
    description: "List activities recorded with a specific piece of gear.",
    inputSchema: {
      gearUuid: z.string().describe("The gear UUID (from get_gear)."),
      start: z.number().int().min(0).optional().describe("Offset for pagination. Default 0."),
      limit: z.number().int().min(1).max(50).optional().describe("How many to return (1-50). Default 20.")
    },
    handler: async (c, a) => c.get(ep.gearActivities(a.gearUuid, a.start ?? 0, a.limit ?? 20))
  },
  {
    name: "get_gear_defaults",
    description: "Get your default gear assignments per activity type.",
    inputSchema: {},
    handler: async (c) => c.get(ep.gearDefaults(await c.getProfileId()))
  },
  // ===================================================================
  // Devices
  // ===================================================================
  {
    name: "get_devices",
    description: "List your registered Garmin devices.",
    inputSchema: {},
    handler: async (c) => c.get(ep.devices())
  },
  {
    name: "get_device_settings",
    description: "Get the settings for a specific device by its device ID.",
    inputSchema: {
      deviceId: z.union([z.string(), z.number()]).describe("The Garmin device ID (from get_devices).")
    },
    handler: async (c, a) => c.get(ep.deviceSettings(a.deviceId))
  },
  {
    name: "get_device_last_used",
    description: "Get info about the most recently used device.",
    inputSchema: {},
    handler: async (c) => c.get(ep.deviceLastUsed())
  },
  {
    name: "get_primary_training_device",
    description: "Get info about your primary training device.",
    inputSchema: {},
    handler: async (c) => c.get(ep.primaryTrainingDevice())
  },
  {
    name: "get_device_solar_data",
    description: "Get solar-charging data for a solar-capable device across a date range.",
    inputSchema: {
      deviceId: z.union([z.string(), z.number()]).describe("The Garmin device ID."),
      ...startEndFields
    },
    handler: async (c, a) => c.get(ep.deviceSolar(a.deviceId, a.startDate, a.endDate))
  },
  // ===================================================================
  // Goals, badges & challenges
  // ===================================================================
  {
    name: "get_goals",
    description: "List your goals filtered by status.",
    inputSchema: {
      status: z.enum(["active", "future", "past"]).optional().describe("Goal status. Default 'active'."),
      start: z.number().int().min(0).optional().describe("Offset for pagination. Default 1.")
    },
    handler: async (c, a) => c.get(ep.goals(a.status ?? "active", a.start ?? 1))
  },
  {
    name: "get_earned_badges",
    description: "List badges you have earned.",
    inputSchema: {},
    handler: async (c) => c.get(ep.earnedBadges())
  },
  {
    name: "get_available_badges",
    description: "List badges available to earn.",
    inputSchema: {},
    handler: async (c) => c.get(ep.availableBadges())
  },
  {
    name: "get_adhoc_challenges",
    description: "List historical ad-hoc challenges.",
    inputSchema: {},
    handler: async (c) => c.get(ep.adhocChallenges())
  },
  {
    name: "get_badge_challenges",
    description: "List completed badge challenges.",
    inputSchema: {},
    handler: async (c) => c.get(ep.badgeChallenges())
  },
  {
    name: "get_available_badge_challenges",
    description: "List badge challenges available to join.",
    inputSchema: {},
    handler: async (c) => c.get(ep.availableBadgeChallenges())
  },
  {
    name: "get_non_completed_badge_challenges",
    description: "List badge challenges you joined but have not completed.",
    inputSchema: {},
    handler: async (c) => c.get(ep.nonCompletedBadgeChallenges())
  },
  {
    name: "get_inprogress_virtual_challenges",
    description: "List in-progress virtual challenges (e.g. expeditions).",
    inputSchema: {},
    handler: async (c) => c.get(ep.inProgressVirtualChallenges())
  },
  // ===================================================================
  // Women's health
  // ===================================================================
  {
    name: "get_menstrual_calendar",
    description: "Get menstrual cycle calendar data across a date range.",
    inputSchema: { ...startEndFields },
    handler: async (c, a) => c.get(ep.menstrualCalendar(a.startDate, a.endDate))
  },
  {
    name: "get_menstrual_data_for_date",
    description: "Get menstrual cycle data for a specific date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.menstrualDayView(resolveDate(a)))
  },
  {
    name: "get_pregnancy_summary",
    description: "Get the pregnancy snapshot/summary.",
    inputSchema: {},
    handler: async (c) => c.get(ep.pregnancySummary())
  },
  {
    name: "get_lifestyle_logging",
    description: "Get lifestyle logging data (logged habits) for a date.",
    inputSchema: { ...dateField },
    handler: async (c, a) => c.get(ep.lifestyleLogging(resolveDate(a)))
  },
  // ===================================================================
  // Profile & calendar
  // ===================================================================
  {
    name: "get_user_profile",
    description: "Get your Garmin social profile (display name, profile ID, etc.).",
    inputSchema: {},
    handler: async (c) => c.get(ep.socialProfile())
  },
  {
    name: "get_user_settings",
    description: "Get your Garmin account user settings (units, preferences, biometrics).",
    inputSchema: {},
    handler: async (c) => c.get(ep.userSettings())
  },
  {
    name: "get_calendar_month",
    description: "Get the activity/event calendar for a given year and month (1-12).",
    inputSchema: {
      year: z.number().int().min(2e3).max(2100).describe("Four-digit year, e.g. 2026."),
      month: z.number().int().min(1).max(12).describe("Month 1-12.")
    },
    handler: async (c, a) => c.get(ep.calendar(a.year, a.month))
  }
];

// src/index.ts
var client = null;
function getClient() {
  if (!client) client = GarminClient.fromCache();
  return client;
}
var server = new McpServer({
  name: "garmin-connect-mcp",
  version: "0.1.0"
});
for (const tool of tools) {
  server.registerTool(
    tool.name,
    {
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      }
    },
    async (args) => {
      try {
        const data = await tool.handler(getClient(), args ?? {});
        return {
          content: [{ type: "text", text: JSON.stringify(data, null, 2) }]
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          isError: true,
          content: [{ type: "text", text: message }]
        };
      }
    }
  );
}
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write("garmin-connect-mcp running on stdio\n");
}
main().catch((err) => {
  process.stderr.write(`Fatal: ${err instanceof Error ? err.message : String(err)}
`);
  process.exit(1);
});
