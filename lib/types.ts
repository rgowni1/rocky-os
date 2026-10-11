export interface MonthlyLog {
  id: string;
  name: string;
  monthOf: string | null;
  // Health
  slpHrs: number | null;
  slpScore: number | null;
  slpHrv: number | null;
  rhr: number | null;
  breathRate: number | null;
  stressLevel: number | null;
  weeklyWeight: number | null;
  bodyFat: number | null;
  // Fitness
  runMiles: number | null;
  bikeMiles: number | null;
  swimYards: number | null;
  loggedTrainingHrs: number | null;
  stepCount: number | null;
  intensityMinutes: number | null;
  strengthMinutes: number | null;
  // Focus & Mind
  deepWork: number | null;
  meditationSessions: number | null;
  totalPhPickUps: number | null;
  articles: number | null;
  podcastsVideos: number | null;
  // Body
  mbs: number | null;
}

export interface Goal {
  id: string;
  name: string;
  status: string | null;
  priority: string | null;
  lifeCategories: string[];
  taskCount: number;
}

export interface TaskSummary {
  total: number;
  done: number;
  inProgress: number;
  notStarted: number;
  byPriority: Record<string, number>;
}
