program MachineHMI;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, uhmimain, uhmidata, umachinedef, uinfluxapi;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Machine HMI';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
