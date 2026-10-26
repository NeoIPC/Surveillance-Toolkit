#Requires -Version 7.6

<#
.SYNOPSIS
    The scripted PowerShell host that the NeoIPC-Tools tests put confirmations to.

.DESCRIPTION
    Defines NeoIPCTests.ScriptedHost, once per process: a host whose user interface answers each choice prompt with the
    next answer of a queue, records every prompt, and refuses every request for input. A prompt with no answer left
    fails, as it fails in a PowerShell that cannot ask. A test file dot-sources this file and runs the command under
    test in a runspace of the host, [runspacefactory]::CreateRunspace([NeoIPCTests.ScriptedHost]::new()).
#>

if (-not ('NeoIPCTests.ScriptedHost' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

namespace NeoIPCTests
{
    // Answers each choice prompt with the next answer of the queue, by position, since the labels come in the UI
    // language: ShouldProcess, and ShouldContinue with yesToAll and noToAll, offer Yes, Yes to All, No, No to All, and
    // Suspend, in that order, and ShouldContinue with a query and a caption only offers Yes, No, and Suspend. Every
    // request for input is recorded in Inputs and refused: Read-Host -Prompt asks through Prompt, with the prompt as the
    // field's name.
    public sealed class ScriptedHostUserInterface : PSHostUserInterface
    {
        private static readonly string[] Positions = { "Yes", "YesToAll", "No", "NoToAll" };
        private static readonly string[] YesNoPositions = { "Yes", "No" };
        public Queue<string> Answers { get; } = new Queue<string>();
        public List<string> Prompts { get; } = new List<string>();
        public List<string> Inputs { get; } = new List<string>();
        public List<string> Warnings { get; } = new List<string>();
        public override PSHostRawUserInterface RawUI => null;
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            Prompts.Add(message);
            if (Answers.Count == 0) throw new InvalidOperationException("Asked with no answer left: " + message);
            int position = Array.IndexOf(choices.Count == 3 ? YesNoPositions : Positions, Answers.Dequeue());
            if (position < 0 || position >= choices.Count) throw new InvalidOperationException("No such answer to: " + message);
            return position;
        }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
        {
            foreach (FieldDescription description in descriptions) Inputs.Add(description.Name);
            throw new InvalidOperationException("Asked for input: " + message);
        }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) { Inputs.Add("a credential"); throw new InvalidOperationException("Asked for a credential."); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) { Inputs.Add("a credential"); throw new InvalidOperationException("Asked for a credential."); }
        public override string ReadLine() { Inputs.Add("a line"); throw new InvalidOperationException("Asked for a line."); }
        public override SecureString ReadLineAsSecureString() { Inputs.Add("a secure line"); throw new InvalidOperationException("Asked for a secure line."); }
        public override void Write(string value) { }
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { }
        public override void WriteLine(string value) { }
        public override void WriteErrorLine(string value) { }
        public override void WriteDebugLine(string message) { }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }
        public override void WriteVerboseLine(string message) { }
        public override void WriteWarningLine(string message) { Warnings.Add(message); }
    }

    public sealed class ScriptedHost : PSHost
    {
        private readonly Guid instanceId = Guid.NewGuid();
        public ScriptedHostUserInterface ScriptedUI { get; } = new ScriptedHostUserInterface();
        public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
        public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
        public override Guid InstanceId => instanceId;
        public override string Name => "NeoIPCTestsScriptedHost";
        public override PSHostUserInterface UI => ScriptedUI;
        public override Version Version => new Version(1, 0);
        public override void EnterNestedPrompt() => throw new NotSupportedException();
        public override void ExitNestedPrompt() => throw new NotSupportedException();
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
        public override void SetShouldExit(int exitCode) { }
    }
}
'@
}
