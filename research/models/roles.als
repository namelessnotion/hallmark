module roles
open catalog

-- Generated from Rolify config + RoleAssignmentPolicy
one sig Author, Editor, Requester, Approver, Support extends Role {}
one sig ReqVsApp extends Conflict {}
one sig SupportAssignsEditor extends CanAssign {}

fact config {
  Role = Admin + Author + Editor + Requester + Approver + Support
  Admin.inherits = Editor + Approver
  Editor.inherits = Author
  no (Author + Requester + Approver + Support).inherits
  Conflict = ReqVsApp
  ReqVsApp.a = Requester and ReqVsApp.b = Approver
  CanAssign = SupportAssignsEditor
  SupportAssignsEditor.by = Support and SupportAssignsEditor.gives = Editor
  -- observed: user assignments may be any subset; SoD enforced at assignment time?
}

check NoHierarchyCycles for 4 but 6 Role
check StaticSoD for 4 but 6 Role
check NoEscalationByAssignment for 4 but 6 Role
