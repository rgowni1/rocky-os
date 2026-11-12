import { NextResponse } from "next/server";
import { queryAll, getSelect, getStatus, DB } from "@/lib/notion";
import type { TaskSummary } from "@/lib/types";

export async function GET() {
  try {
    const pages = await queryAll(DB.tasks);

    const summary: TaskSummary = {
      total: pages.length,
      done: 0,
      inProgress: 0,
      notStarted: 0,
      byPriority: {},
    };

    for (const page of pages) {
      const status = getStatus(page, "Status - New");
      if (status === "Done") summary.done++;
      else if (status === "In Progress" || status === "Focus") summary.inProgress++;
      else summary.notStarted++;

      const priority = getSelect(page, "Priority");
      if (priority) {
        summary.byPriority[priority] = (summary.byPriority[priority] ?? 0) + 1;
      }
    }

    return NextResponse.json(summary);
  } catch (e: any) {
    return NextResponse.json({ error: e.message }, { status: 500 });
  }
}
