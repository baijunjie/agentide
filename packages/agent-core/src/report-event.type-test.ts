import type {
  PlanReportPayload,
  ReportEventInput,
  TodoReportPayload,
} from "./index.js";

type Equal<Left, Right> =
  (<Value>() => Value extends Left ? 1 : 2) extends
  (<Value>() => Value extends Right ? 1 : 2)
    ? true
    : false;
type Expect<Value extends true> = Value;

type TodoReport = Extract<ReportEventInput, { kind: "todo" }>;
type InvalidTodoMatches = {
  type: "report";
  reportVersion: 1;
  reportId: string;
  kind: "todo";
  title: string;
  summary: string;
  payload: PlanReportPayload;
} extends ReportEventInput ? true : false;

type TodoPayloadNarrows = Expect<Equal<TodoReport["payload"], TodoReportPayload>>;
type InvalidTodoIsRejected = Expect<Equal<InvalidTodoMatches, false>>;

export type { InvalidTodoIsRejected, TodoPayloadNarrows };
