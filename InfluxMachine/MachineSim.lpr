program MachineSim;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, usimmain, umachinesim, umachinedef, uinfluxapi;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Machine Simulator';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
