---
name: design-feature
description: Feature design methodology — requirements gathering, design, story breakdown
---

# Feature Design Methodology

## Step 1: Requirements Interview
Do NOT start designing immediately. Ask clarifying questions first:
- What problem does this solve? Who is the user?
- What are the edge cases the requirements don't mention?
- Backward compatibility concerns?
- Performance implications at scale?
- Interaction with existing features?
- What should happen on failure/rollback?
- UI, API, or both?

Ask questions in batches of 3-5. Wait for answers. Follow up.
Say "I have enough to start the design. Ready?" before proceeding.

## Step 2: Analyze Existing Code
- Understand the current patterns in the affected area
- Identify models, controllers, actions, services, and UI components involved
- Note conventions that new code must follow

## Step 3: Produce Design Document
- Data model changes (new models, migrations, associations)
- API changes (new endpoints, modified responses)
- Background job / async processing changes
- UI changes
- Permission / authorization requirements
- External service interactions

## Step 4: Break Into Stories
- Clear acceptance criteria per story
- Estimated complexity (S/M/L)
- Dependencies between stories
- Test strategy per story

## Step 5: Identify Risks
- Migration risks
- Backward compatibility
- Integration test needs
