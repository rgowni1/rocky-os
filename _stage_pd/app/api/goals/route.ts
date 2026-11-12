import { NextResponse } from "next/server";
import { queryAll, getText, getSelect, getStatus, getMultiSelect, DB } from "@/lib/notion";
import type { Goal } from "@/lib/types";

export async function GET() {
  try {
    const pages = await queryAll(DB.goals);

    const goals: Goal[] = pages.map((page: any) => {
      const tasksRelation = page.properties?.["Tasks"];
      const taskCount =
        tasksRelation?.type === "relation" ? tasksRelation.relation?.length ?? 0 : 0;

      return {
        id: page.id,
        name: getText(page, "Project name"),
        status: getStatus(page, "Status"),
        priority: getSelect(page, "Priority"),
        lifeCategories: getMultiSelect(page, "Life Category"),
        taskCount,
      };
    });

    return NextResponse.json(goals);
  } catch (e: any) {
    return NextResponse.json({ error: e.message }, { status: 500 });
  }
}
